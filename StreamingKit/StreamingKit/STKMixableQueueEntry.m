//
//  STKMixableQueueEntry.m
//  StreamingKit
//
//  Created by James Gordon on 09/12/2014.
//

#import <pthread/pthread.h>
#import "STKConstants.h"
#import "STKMixableQueueEntry.h"

static AudioStreamBasicDescription canonicalAudioStreamBasicDescription;
const int k_readBufferSize = 64 * 1024;


@interface STKMixableQueueEntry() {
    
    OSSpinLock _internalStateLock;
    
    UInt32 _readBufferSize;
    UInt8 *_readBuffer;
    AudioBufferList _pcmAudioBufferList;
    
//    BOOL deallocating;
//    NSArray* frameFilters;
//    NSThread* playbackThread;
//    NSRunLoop* playbackThreadRunLoop;
//    NSConditionLock* threadStartedLock;
//    NSConditionLock* threadFinishedCondLock;
    
//    void(^stopBackBackgroundTaskBlock)();
    
//    int32_t seekVersion;
//    OSSpinLock seekLock;
//    OSSpinLock currentEntryReferencesLock;
    
    pthread_mutex_t _entryMutex;
    pthread_cond_t _playerThreadReadyCondition;
//    pthread_mutex_t _mainThreadSyncCallMutex;
//    pthread_cond_t _mainThreadSyncCallReadyCondition;
    
    AudioFileStreamID _fileStream;
    AudioConverterRef _audioConverter;
    AudioStreamBasicDescription _audioConverterAudioStreamBasicDescription;
    
    UInt32 _bytesPerSample;
    UInt32 _channelsPerFrame;
    
    volatile UInt32 _pcmBufferTotalFrameCount;
    volatile UInt32 _pcmBufferFrameStartIndex;
    volatile UInt32 _pcmBufferUsedFrameCount;
    volatile UInt32 _pcmBufferFrameSizeInBytes;
    
    BOOL _discontinuousData;
    BOOL _waiting;
}

@end


@implementation STKMixableQueueEntry




/*
 @brief Start load of the entry and register for data-related events
 
 TODO: If blocking the download thread for queued track causes timeouts of download,
 will need to download the entire track ASAP and then use thread blocking for just the parsing and buffering.
 
 @param runLoop on which to process entry data
 
 @return void
 */
- (void)beginEntryLoadWithRunLoop:(NSRunLoop *)runLoop {
    
    _bytesPerSample = 2;
    _channelsPerFrame = 2;
    
    canonicalAudioStreamBasicDescription = (AudioStreamBasicDescription)
    {
        .mSampleRate = 44100.00,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mFramesPerPacket = 1,
        .mChannelsPerFrame = 2,
        .mBytesPerFrame = _bytesPerSample * _channelsPerFrame,
        .mBitsPerChannel = 8 * _bytesPerSample,
        .mBytesPerPacket = _bytesPerSample * _channelsPerFrame
    };
    
    _readBuffer = calloc(sizeof(UInt8), k_readBufferSize);
    _pcmAudioBuffer = &_pcmAudioBufferList.mBuffers[0];
    
    _pcmAudioBufferList.mNumberBuffers = 1;
    _pcmAudioBufferList.mBuffers[0].mDataByteSize = (canonicalAudioStreamBasicDescription.mSampleRate * 10) * canonicalAudioStreamBasicDescription.mBytesPerFrame;
    _pcmAudioBufferList.mBuffers[0].mData = (void*)calloc(_pcmAudioBuffer->mDataByteSize, 1);
    _pcmAudioBufferList.mBuffers[0].mNumberChannels = 2;
    
    _pcmBufferFrameSizeInBytes = canonicalAudioStreamBasicDescription.mBytesPerFrame;
    _pcmBufferTotalFrameCount = _pcmAudioBuffer->mDataByteSize / _pcmBufferFrameSizeInBytes;
    
    pthread_mutexattr_t attr;
    
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    
    pthread_mutex_init(&_entryMutex, &attr);
    pthread_cond_init(&_playerThreadReadyCondition, NULL);
    
    self.dataSource.delegate = self;
    
    [self.dataSource registerForEvents:runLoop];
    [self.dataSource seekToOffset:0];
}


/*
 @breif Unblock the downloading/parsing thread
 */
- (void)continueBuffering {
    pthread_mutex_lock(&_entryMutex);
    
    if (_waiting)
    {
        pthread_cond_signal(&_playerThreadReadyCondition);
    }
    
    pthread_mutex_unlock(&_entryMutex);
}



#pragma mark Data Source Delegate

-(void) dataSourceDataAvailable:(STKDataSource*)dataSourceIn {
    
    OSStatus error;
    
    if (self.dataSource != dataSourceIn)
    {
        return;
    }
    
    if (!self.dataSource.hasBytesAvailable)
    {
        return;
    }
    
    int read = [self.dataSource readIntoBuffer:_readBuffer withSize:k_readBufferSize];
    if (read == 0)
    {
        return;
    }
    
    if (_fileStream == 0)
    {
        error = AudioFileStreamOpen((__bridge void*)self, AudioFileStreamPropertyListenerProc, AudioFileStreamPacketsProc, dataSourceIn.audioFileTypeHint, &_fileStream);
        if (error)
        {
//            [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
            return;
        }
    }
    
    if (read < 0)
    {
        // iOS will shutdown network connections if the app is backgrounded (i.e. device is locked when player is paused)
        // We try to reopen -- should probably add a back-off protocol in the future
        
        SInt64 position = self.dataSource.position;
        [self.dataSource seekToOffset:position];
        
        return;
    }
    
    int flags = 0;
    if (_discontinuousData)
    {
        flags = kAudioFileStreamParseFlag_Discontinuity;
    }
    
    if (_fileStream)
    {
        error = AudioFileStreamParseBytes(_fileStream, read, _readBuffer, flags);
        if (error)
        {
            if (dataSourceIn == self.dataSource)
            {
//                [self unexpectedError:STKAudioPlayerErrorStreamParseBytesFailed];
            }
            
            return;
        }
    }
}

-(void) dataSourceErrorOccured:(STKDataSource*)dataSource {
    NSLog(@"I'm probably going to crash; data source error");
}

-(void) dataSourceEof:(STKDataSource*)dataSource {
    NSLog(@"I will probably crash; out of data");
}



#pragma mark Audio Converter management


static BOOL GetHardwareCodecClassDesc(UInt32 formatId, AudioClassDescription* classDesc)
{
#if TARGET_OS_IPHONE
    UInt32 size;
    
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, sizeof(formatId), &formatId, &size) != 0)
    {
        return NO;
    }
    
    UInt32 decoderCount = size / sizeof(AudioClassDescription);
    AudioClassDescription encoderDescriptions[decoderCount];
    
    if (AudioFormatGetProperty(kAudioFormatProperty_Decoders, sizeof(formatId), &formatId, &size, encoderDescriptions) != 0)
    {
        return NO;
    }
    
    for (UInt32 i = 0; i < decoderCount; ++i)
    {
        if (encoderDescriptions[i].mManufacturer == kAppleHardwareAudioCodecManufacturer)
        {
            *classDesc = encoderDescriptions[i];
            return YES;
        }
    }
#endif
    
    return NO;
}

-(void) destroyAudioConverter
{
    if (_audioConverter)
    {
        AudioConverterDispose(_audioConverter);
        _audioConverter = nil;
    }
}

-(void) createAudioConverter:(AudioStreamBasicDescription*)asbd
{
    OSStatus status;
    Boolean writable;
    UInt32 cookieSize = 0;
    
    if (memcmp(asbd, &_audioConverterAudioStreamBasicDescription, sizeof(AudioStreamBasicDescription)) == 0)
    {
        AudioConverterReset(_audioConverter);
        return;
    }
    
    [self destroyAudioConverter];
    
    AudioClassDescription classDesc;
    
    if (GetHardwareCodecClassDesc(asbd->mFormatID, &classDesc))
    {
        AudioConverterNewSpecific(asbd, &canonicalAudioStreamBasicDescription, 1,  &classDesc, &_audioConverter);
    }
    
    if (!_audioConverter)
    {
        status = AudioConverterNew(asbd, &canonicalAudioStreamBasicDescription, &_audioConverter);
        
        if (status)
        {
//            [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
            return;
        }
    }
    
    _audioConverterAudioStreamBasicDescription = *asbd;
    
    if (self.dataSource.audioFileTypeHint != kAudioFileAAC_ADTSType)
    {
        status = AudioFileStreamGetPropertyInfo(_fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
        if (status)
        {
            return;
        }
        
        void* cookieData = alloca(cookieSize);

        status = AudioFileStreamGetProperty(_fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
        if (status)
        {
            return;
        }
        
        status = AudioConverterSetProperty(_audioConverter, kAudioConverterDecompressionMagicCookie, cookieSize, &cookieData);
        if (status)
        {
//            [self unexpectedError:STKAudioPlayerErrorAudioSystemError];
            return;
        }
    }
}


OSStatus EntryAudioConverterCallback(AudioConverterRef inAudioConverter, UInt32* ioNumberDataPackets, AudioBufferList* ioData, AudioStreamPacketDescription **outDataPacketDescription, void* inUserData)
{
    AudioConvertInfo* convertInfo = (AudioConvertInfo*)inUserData;
    if (convertInfo->done)
    {
        ioNumberDataPackets = 0;
        return 100;
    }
    
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0] = convertInfo->audioBuffer;
    
    NSLog(@"BUFFER SIZE: %d", (unsigned int)ioData->mBuffers[0].mDataByteSize);
    
    if (outDataPacketDescription)
    {
        *outDataPacketDescription = convertInfo->packetDescriptions;
    }
    
    *ioNumberDataPackets = convertInfo->numberOfPackets;
    convertInfo->done = YES;
    
    return 0;
}



#pragma mark Audio stream parsing

static void AudioFileStreamPropertyListenerProc(void* clientData, AudioFileStreamID audioFileStream, AudioFileStreamPropertyID	propertyId, UInt32* flags)
{
    STKMixableQueueEntry *entry = (__bridge STKMixableQueueEntry *)clientData;
    [entry handlePropertyChangeForFileStream:audioFileStream fileStreamPropertyID:propertyId ioFlags:flags];
}

-(void) handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID ioFlags:(UInt32*)ioFlags
{
    OSStatus error;
    
    switch (inPropertyID)
    {
        case kAudioFileStreamProperty_DataOffset:
        {
            SInt64 offset;
            UInt32 offsetSize = sizeof(offset);
            
            AudioFileStreamGetProperty(_fileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset);
            
            self->parsedHeader = YES;
            self->audioDataOffset = offset;
            
            break;
        }
        case kAudioFileStreamProperty_FileFormat:
        {
            char fileFormat[4];
            UInt32 fileFormatSize = sizeof(fileFormat);
            
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FileFormat, &fileFormatSize, &fileFormat);
            
            break;
        }
        case kAudioFileStreamProperty_DataFormat:
        {
            AudioStreamBasicDescription newBasicDescription;
            if (!self->parsedHeader)
            {
                UInt32 size = sizeof(newBasicDescription);
                
                AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &size, &newBasicDescription);
                
                pthread_mutex_lock(&_entryMutex);
                
                if (self->audioStreamBasicDescription.mFormatID == 0)
                {
                    self->audioStreamBasicDescription = newBasicDescription;
                }
                
                self->sampleRate = self->audioStreamBasicDescription.mSampleRate;
                self->packetDuration = self->audioStreamBasicDescription.mFramesPerPacket / self->sampleRate;
                
                UInt32 streamPacketBufferSize = 0;
                UInt32 sizeOfStreamPacketBufferSize = sizeof(packetBufferSize);
                
                error = AudioFileStreamGetProperty(_fileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfStreamPacketBufferSize, &streamPacketBufferSize);
                
                if (error || streamPacketBufferSize == 0)
                {
                    error = AudioFileStreamGetProperty(_fileStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfStreamPacketBufferSize, &streamPacketBufferSize);
                    
                    if (error || streamPacketBufferSize == 0)
                    {
                        self->packetBufferSize = STK_DEFAULT_PACKET_BUFFER_SIZE;
                    }
                    else
                    {
                        self->packetBufferSize = streamPacketBufferSize;
                    }
                }
                else
                {
                    self->packetBufferSize = streamPacketBufferSize;
                }
                
                [self createAudioConverter:&audioStreamBasicDescription];
                
                pthread_mutex_unlock(&_entryMutex);
            }
            
            break;
        }
        case kAudioFileStreamProperty_AudioDataByteCount:
        {
            UInt32 byteCountSize = sizeof(self->audioDataByteCount);
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &(self->audioDataByteCount));
            
            break;
        }
        case kAudioFileStreamProperty_ReadyToProducePackets:
        {
            if (kAudioFormatLinearPCM != _audioConverterAudioStreamBasicDescription.mFormatID)
            {
                _discontinuousData = YES;
            }
            
            break;
        }
        case kAudioFileStreamProperty_FormatList:
        {
            Boolean outWriteable;
            UInt32 formatListSize;
            OSStatus err = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
            
            if (err)
            {
                break;
            }
            
            AudioFormatListItem* formatList = malloc(formatListSize);
            
            err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
            
            if (err)
            {
                free(formatList);
                break;
            }
            
            for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
            {
                AudioStreamBasicDescription pasbd = formatList[i].mASBD;
                if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE || pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
                {
                    self->audioStreamBasicDescription = pasbd;
                    break;
                }
            }
            
            free(formatList);
            
            break;
        }
    }
}


static void AudioFileStreamPacketsProc(void* clientData, UInt32 numberBytes, UInt32 numberPackets, const void* inputData, AudioStreamPacketDescription* packetDescriptions)
{
    STKMixableQueueEntry* entry = (__bridge STKMixableQueueEntry*)clientData;
    [entry handleAudioPackets:inputData numberBytes:numberBytes numberPackets:numberPackets packetDescriptions:packetDescriptions];
}


-(void) handleAudioPackets:(const void*)inputData numberBytes:(UInt32)numberBytes numberPackets:(UInt32)numberPackets packetDescriptions:(AudioStreamPacketDescription*)packetDescriptionsIn {
    
    if (!self->parsedHeader)
    {
        return;
    }
    
//    if (disposeWasRequested)
//    {
//        return;
//    }
    
    if (_audioConverter == nil)
    {
        return;
    }
    
//    if ((seekToTimeWasRequested && [currentlyPlayingEntry calculatedBitRate] > 0.0))
//    {
//        [self wakeupPlaybackThread];
//        return;
//    }
    
    _discontinuousData = NO;
    
    OSStatus status = 0;
    
    AudioConvertInfo convertInfo;
    
    convertInfo.done = NO;
    convertInfo.numberOfPackets = numberPackets;
    convertInfo.packetDescriptions = packetDescriptionsIn;
    convertInfo.audioBuffer.mData = (void *)inputData;
    convertInfo.audioBuffer.mDataByteSize = numberBytes;
    convertInfo.audioBuffer.mNumberChannels = _audioConverterAudioStreamBasicDescription.mChannelsPerFrame;
    
    if (packetDescriptionsIn && self->processedPacketsCount < STK_MAX_COMPRESSED_PACKETS_FOR_BITRATE_CALCULATION)
    {
        int count = MIN(numberPackets, STK_MAX_COMPRESSED_PACKETS_FOR_BITRATE_CALCULATION - self->processedPacketsCount);
        for (int i = 0; i < count; i++)
        {
            SInt64 packetSize;
            
            packetSize = packetDescriptionsIn[i].mDataByteSize;
            
            OSAtomicAdd32((int32_t)packetSize, &self->processedPacketsSizeTotal);
            OSAtomicIncrement32(&self->processedPacketsCount);
        }
    }
    
    while (true)
    {
        OSSpinLockLock(&self->spinLock);
        UInt32 used = _pcmBufferUsedFrameCount;
        UInt32 start = _pcmBufferFrameStartIndex;
        UInt32 end = (_pcmBufferFrameStartIndex + _pcmBufferUsedFrameCount) % _pcmBufferTotalFrameCount;
        UInt32 framesLeftInsideBuffer = _pcmBufferTotalFrameCount - used;
        OSSpinLockUnlock(&self->spinLock);
        
        if (framesLeftInsideBuffer == 0)
        {
            pthread_mutex_lock(&_entryMutex);
            
            while (true)
            {
                OSSpinLockLock(&self->spinLock);
                used = _pcmBufferUsedFrameCount;
                start = _pcmBufferFrameStartIndex;
                end = (_pcmBufferFrameStartIndex + _pcmBufferUsedFrameCount) % _pcmBufferTotalFrameCount;
                framesLeftInsideBuffer = _pcmBufferTotalFrameCount - used;
                OSSpinLockUnlock(&self->spinLock);
                
                if (framesLeftInsideBuffer > 0)
                {
                    break;
                }
                
//                if  (disposeWasRequested
//                     || self.internalState == STKAudioPlayerInternalStateStopped
//                     || self.internalState == STKAudioPlayerInternalStateDisposed
//                     || self.internalState == STKAudioPlayerInternalStatePendingNext)
//                {
//                    pthread_mutex_unlock(&_entryMutex);
//                    
//                    return;
//                }
                
//                if (seekToTimeWasRequested && [self calculatedBitRate] > 0.0)
//                {
//                    pthread_mutex_unlock(&_entryMutex);
//                    
//                    [self wakeupPlaybackThread];
//                    
//                    return;
//                }
                
                _waiting = YES;
                
                pthread_cond_wait(&_playerThreadReadyCondition, &_entryMutex);
                
                _waiting = NO;
            }
            
            pthread_mutex_unlock(&_entryMutex);
        }
        
        AudioBuffer* localPcmAudioBuffer;
        AudioBufferList localPcmBufferList;
        
        localPcmBufferList.mNumberBuffers = 1;
        localPcmAudioBuffer = &localPcmBufferList.mBuffers[0];
        
        if (end >= start)
        {
            UInt32 framesAdded = 0;
            UInt32 framesToDecode = _pcmBufferTotalFrameCount - end;
            
            localPcmAudioBuffer->mData = _pcmAudioBuffer->mData + (end * _pcmBufferFrameSizeInBytes);
            localPcmAudioBuffer->mDataByteSize = framesToDecode * _pcmBufferFrameSizeInBytes;
            localPcmAudioBuffer->mNumberChannels = _pcmAudioBuffer->mNumberChannels;
            
            status = AudioConverterFillComplexBuffer(_audioConverter, EntryAudioConverterCallback, (void*)&convertInfo, &framesToDecode, &localPcmBufferList, NULL);
            
            framesAdded = framesToDecode;
            
            if (status == 100)
            {
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);
                
                return;
            }
            else if (status != 0)
            {
//                [self unexpectedError:STKAudioPlayerErrorCodecError];
                return;
            }
            
            framesToDecode = start;
            
            if (framesToDecode == 0)
            {
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);
                
                continue;
            }
            
            localPcmAudioBuffer->mData = _pcmAudioBuffer->mData;
            localPcmAudioBuffer->mDataByteSize = framesToDecode * _pcmBufferFrameSizeInBytes;
            localPcmAudioBuffer->mNumberChannels = _pcmAudioBuffer->mNumberChannels;
            
            status = AudioConverterFillComplexBuffer(_audioConverter, EntryAudioConverterCallback, (void*)&convertInfo, &framesToDecode, &localPcmBufferList, NULL);
            
            framesAdded += framesToDecode;
            
            if (status == 100)
            {
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);
                
                return;
            }
            else if (status == 0)
            {
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);
                
                continue;
            }
            else if (status != 0)
            {
//                [self unexpectedError:STKAudioPlayerErrorCodecError];
                return;
            }
        }
        else
        {
            UInt32 framesAdded = 0;
            UInt32 framesToDecode = start - end;
            
            localPcmAudioBuffer->mData = _pcmAudioBuffer->mData + (end * _pcmBufferFrameSizeInBytes);
            localPcmAudioBuffer->mDataByteSize = framesToDecode * _pcmBufferFrameSizeInBytes;
            localPcmAudioBuffer->mNumberChannels = _pcmAudioBuffer->mNumberChannels;
            
            status = AudioConverterFillComplexBuffer(_audioConverter, EntryAudioConverterCallback, (void*)&convertInfo, &framesToDecode, &localPcmBufferList, NULL);
            
            framesAdded = framesToDecode;
            
            if (status == 100)
            {
                // TODO: This is used about a million times. Move to function
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);
                
                return;
            }
            else if (status == 0)
            {
                OSSpinLockLock(&self->spinLock);
                _pcmBufferUsedFrameCount += framesAdded;
                self->framesQueued += framesAdded;
                OSSpinLockUnlock(&self->spinLock);

                continue;
            }
            else if (status != 0)
            {
//                [self unexpectedError:STKAudioPlayerErrorCodecError];
                return;
            }
        }
    }
}

@end