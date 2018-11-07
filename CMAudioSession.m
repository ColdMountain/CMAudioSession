//
//  CMAudioSession.m
//  CMSocketServer
//
//  Created by coldMountain on 2018/10/16.
//  Copyright © 2018 ColdMountain. All rights reserved.
//
/*******************************************************************************************/

// 该类主要是为了满足后台持续采集音频而做，之前使用AVCaptureSession 同步采集音视频的方式在app 切换至后台的时候音频
// 并不能采集，需使用AVAudioSession 配合 底层库AudioUnit来完成

// 具体的步骤
// 1、初始化方法中先对输出的音频相关配置进行设置
// 2、初始化采集时的需接收的PCM数据
// 3、初始化AudioUnit相关的属性输出开关 回声消除
// 4、初始化转码器(PCM->AAC)
// 5、初始化回调函数
// 6、当外部调用startAudioUnitRecorder函数时，初始化数据源开始采集音频
// 7、通过回调方法数据发送给转码器
// 8、在转码器中得到转码的AAC数据，之后对它进行ADTS头拼接，生成我们需要的NSData数据最终回调回去

/*******************************************************************************************/
#import "CMAudioSession.h"
//#import <AudioUnit/AudioUnit.h>

#define kPCMMaxBuffSize           2048

AudioConverterRef               _encodeConvertRef = NULL;
AudioStreamBasicDescription     _targetDes;

static int          pcm_buffer_size = 0;
static uint8_t      pcm_buffer[kPCMMaxBuffSize*2];

enum ChannelCount
{
    k_Mono = 1,
    k_Stereo
};

@interface CMAudioSession()
{
    AudioUnit                        _audioUnit;
    AudioBufferList                 *_buffList;
    AudioStreamBasicDescription     dataFormat;
}
@end

@implementation CMAudioSession

- (id)init{
    if (self=[super init]) {
        [self initAudioComponent];
        [self initBuffer];
        [self setAudioUnitPropertyAndFormat];
        [self convertBasicSetting];
        [self initRecordeCallback];
        OSStatus status = AudioUnitInitialize(_audioUnit);
        if (status != noErr) {
        }
    }
    return self;
}

- (void)initGlobalVar {
    // 初始化pcm_buffer，pcm_buffer是存储每次捕获的PCM数据
    // 因为PCM若要转成AAC需要攒够2048个字节给转换器才能完成一次转换
    memset(pcm_buffer, 0, pcm_buffer_size);
    pcm_buffer_size = 0;
}

- (void)initAudioComponent {
    OSStatus status;
    // 配置AudioUnit基本信息
    AudioComponentDescription audioDesc;
    audioDesc.componentType         = kAudioUnitType_Output;
    // 如果你的应用程序需要去除回声将componentSubType设置为kAudioUnitSubType_VoiceProcessingIO，否则根据需求设置为其他，在博客中有介绍
    audioDesc.componentSubType      = kAudioUnitSubType_VoiceProcessingIO;//kAudioUnitSubType_VoiceProcessingIO;
    // 苹果自己的标志
    audioDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    audioDesc.componentFlags        = 0;
    audioDesc.componentFlagsMask    = 0;
    
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &audioDesc);
    // 新建一个AudioComponent对象，只有这步完成才能进行后续步骤，所以顺序不可颠倒
    status = AudioComponentInstanceNew(inputComponent, &_audioUnit);
    if (status != noErr)  {
        _audioUnit = NULL;
        NSLog(@"couldn't create a new instance of AURemoteIO, status : %d \n",status);
    }
}

- (void)initBuffer {
    // 禁用AudioUnit默认的buffer而使用我们自己写的全局BUFFER,用来接收每次采集的PCM数据，Disable AU buffer allocation for the recorder, we allocate our own.
    UInt32 flag     = 0;
    OSStatus status = AudioUnitSetProperty(_audioUnit,
                                           kAudioUnitProperty_ShouldAllocateBuffer,
                                           kAudioUnitScope_Output,
                                           1,
                                           &flag,
                                           sizeof(flag));
    if (status != noErr) {
        //        log4cplus_info("Audio Recoder", "couldn't AllocateBuffer of AudioUnitCallBack, status : %d \n",status);
    }
    _buffList = (AudioBufferList*)malloc(sizeof(AudioBufferList));
    _buffList->mNumberBuffers               = 1;
    _buffList->mBuffers[0].mNumberChannels  = dataFormat.mChannelsPerFrame;
    _buffList->mBuffers[0].mDataByteSize    = kPCMMaxBuffSize * sizeof(short);
    _buffList->mBuffers[0].mData            = (short *)malloc(sizeof(short) * kPCMMaxBuffSize);
}

// 因为本例只做录音功能，未实现播放功能，所以没有设置播放相关设置。
- (void)setAudioUnitPropertyAndFormat {
    OSStatus status;
    [self setUpRecoderWithFormatID:kAudioFormatLinearPCM];
    
    // 应用audioUnit设置的格式
    status = AudioUnitSetProperty(_audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  1,
                                  &dataFormat,
                                  sizeof(dataFormat));
    if (status != noErr) {
        NSLog(@"couldn't set the input client format on AURemoteIO, status : %d \n",status);
    }
    // 去除回声开关
    UInt32 echoCancellation;
    AudioUnitSetProperty(_audioUnit,
                         kAUVoiceIOProperty_BypassVoiceProcessing,
                         kAudioUnitScope_Global,
                         0,
                         &echoCancellation,
                         sizeof(echoCancellation));
    
    // AudioUnit输入端默认是关闭，需要将他打开
    UInt32 flag = 1;
    status      = AudioUnitSetProperty(_audioUnit,
                                       kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input,
                                       1,
                                       &flag,
                                       sizeof(flag));
    
    if (status != noErr) {
        NSLog(@"could not enable input on AURemoteIO, status : %d \n",status);
    }
}

-(void)setUpRecoderWithFormatID:(UInt32)formatID {
    // Notice : The settings here are official recommended settings,can be changed according to specific requirements. 此处的设置为官方推荐设置,可根据具体需求修改部分设置
    //setup auido sample rate, channel number, and format ID
    memset(&dataFormat, 0, sizeof(dataFormat));
    
    UInt32 size = sizeof(dataFormat.mSampleRate);
    AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate,
                            &size,
                            &dataFormat.mSampleRate);
    dataFormat.mSampleRate = 44100;
    
    size = sizeof(dataFormat.mChannelsPerFrame);
    AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareInputNumberChannels,
                            &size,
                            &dataFormat.mChannelsPerFrame);
    dataFormat.mFormatID = formatID;
    dataFormat.mChannelsPerFrame = 1;
    
    if (formatID == kAudioFormatLinearPCM) {
        dataFormat.mFormatFlags     = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        dataFormat.mBitsPerChannel  = 16;
        dataFormat.mBytesPerPacket  = dataFormat.mBytesPerFrame = (dataFormat.mBitsPerChannel / 8) * dataFormat.mChannelsPerFrame;
        dataFormat.mFramesPerPacket = 1; // 用AudioQueue采集pcm需要这么设置
    }
}

- (void)initRecordeCallback {
    // 设置回调，有两种方式，一种是采集pcm的BUFFER使用系统回调中的参数，另一种是使用我们自己的，本例中使用的是自己的，所以回调中的ioData为空。如果想要使用回调中的请看博客另一种设置方法。
    AURenderCallbackStruct recordCallback;
    recordCallback.inputProc        = RecordCallback;
    recordCallback.inputProcRefCon  = (__bridge void *)self;
    OSStatus status                 = AudioUnitSetProperty(_audioUnit,
                                                           kAudioOutputUnitProperty_SetInputCallback,
                                                           kAudioUnitScope_Global,
                                                           1,
                                                           &recordCallback,
                                                           sizeof(recordCallback));
    
    if (status != noErr) {
        NSLog(@"Audio Unit set record Callback failed, status : %d \n",status);
    }
}

- (NSString *)convertBasicSetting {
    // 此处目标格式其他参数均为默认，系统会自动计算，否则无法进入encodeConverterComplexInputDataProc回调
    AudioStreamBasicDescription sourceDes = dataFormat;
    AudioStreamBasicDescription targetDes;
    
    memset(&targetDes, 0, sizeof(targetDes));
    targetDes.mFormatID                   = kAudioFormatMPEG4AAC;
    targetDes.mSampleRate                 = 44100;
    targetDes.mChannelsPerFrame           = dataFormat.mChannelsPerFrame;
    targetDes.mFramesPerPacket            = 1024;
    
    OSStatus status     = 0;
    UInt32 targetSize   = sizeof(targetDes);
    status              = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &targetSize, &targetDes);
    //    log4cplus_info("pcm", "create target data format status:%d",(int)status);
    
    memset(&_targetDes, 0, sizeof(_targetDes));
    memcpy(&_targetDes, &targetDes, targetSize);
    
    // select software coding,选择软件编码
    AudioClassDescription audioClassDes;
    status = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders,
                                        sizeof(targetDes.mFormatID),
                                        &targetDes.mFormatID,
                                        &targetSize);
    
    UInt32 numEncoders = targetSize/sizeof(AudioClassDescription);
    AudioClassDescription audioClassArr[numEncoders];
    AudioFormatGetProperty(kAudioFormatProperty_Encoders,
                           sizeof(targetDes.mFormatID),
                           &targetDes.mFormatID,
                           &targetSize,
                           audioClassArr);
    
    for (int i = 0; i < numEncoders; i++) {
        if (audioClassArr[i].mSubType == kAudioFormatMPEG4AAC && audioClassArr[i].mManufacturer == kAppleSoftwareAudioCodecManufacturer) {
            memcpy(&audioClassDes, &audioClassArr[i], sizeof(AudioClassDescription));
            break;
        }
    }
    
    if (_encodeConvertRef == NULL) {
        status          = AudioConverterNewSpecific(&sourceDes, &targetDes, 1,
                                                    &audioClassDes, &_encodeConvertRef);
        
        if (status != noErr) {
            return @"Error : New convertRef failed \n";
        }
    }
    
    targetSize      = sizeof(sourceDes);
    status          = AudioConverterGetProperty(_encodeConvertRef, kAudioConverterCurrentInputStreamDescription, &targetSize, &sourceDes);
    
    targetSize      = sizeof(targetDes);
    status          = AudioConverterGetProperty(_encodeConvertRef, kAudioConverterCurrentOutputStreamDescription, &targetSize, &targetDes);
    
    // 设置码率，需要和采样率对应
    UInt32 bitRate  = 44100;
    targetSize      = sizeof(bitRate);
    status          = AudioConverterSetProperty(_encodeConvertRef,
                                                kAudioConverterEncodeBitRate,
                                                targetSize, &bitRate);
    if (status != noErr) {
        return @"Error : Set covert property bit rate failed";
    }
    
    return nil;
}


static OSStatus RecordCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData) {
    /*
     注意：如果采集的数据是PCM需要将dataFormat.mFramesPerPacket设置为1，而本例中最终要的数据为AAC,因为本例中使用的转换器只有每次传入1024帧才能开始工作,所以在AAC格式下需要将mFramesPerPacket设置为1024.也就是采集到的inNumPackets为1，在转换器中传入的inNumPackets应该为AAC格式下默认的1，在此后写入文件中也应该传的是转换好的inNumPackets,如果有特殊需求需要将采集的数据量小于1024,那么需要将每次捕捉到的数据先预先存储在一个buffer中,等到攒够1024帧再进行转换。
     */
    
    CMAudioSession *session = (__bridge CMAudioSession *)inRefCon;
    
    // 将回调数据传给_buffList
    AudioUnitRender(session->_audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, session->_buffList);
    
    void    *bufferData = session->_buffList->mBuffers[0].mData;
    UInt32   bufferSize = session->_buffList->mBuffers[0].mDataByteSize;
    //    printf("Audio Recoder Render dataSize : %d \n",bufferSize);
    
    float channelValue[2];
    caculate_bm_db(bufferData, bufferSize, 0, k_Mono, channelValue,true);
    
    // 由于PCM转成AAC的转换器每次需要有1024个采样点（每一帧2个字节）才能完成一次转换，所以每次需要2048大小的数据，这里定义的pcm_buffer用来累加每次存储的bufferData
    memcpy(pcm_buffer+pcm_buffer_size, bufferData, bufferSize);
    pcm_buffer_size = pcm_buffer_size + bufferSize;
    
    if(pcm_buffer_size >= kPCMMaxBuffSize) {
        AudioBufferList *bufferList = convertPCMToAAC(session);
        
        // 因为采样不可能每次都精准的采集到1024个样点，所以如果大于2048大小就先填满2048，剩下的跟着下一次采集一起送给转换器
        memcpy(pcm_buffer, pcm_buffer + kPCMMaxBuffSize, pcm_buffer_size - kPCMMaxBuffSize);
        pcm_buffer_size = pcm_buffer_size - kPCMMaxBuffSize;
        
        // free memory
        if(bufferList) {
            free(bufferList->mBuffers[0].mData);
            free(bufferList);
        }
    }
    
    return noErr;
}

// PCM -> AAC
AudioBufferList* convertPCMToAAC (CMAudioSession *recoder) {
    
    UInt32   maxPacketSize    = 0;
    UInt32   size             = sizeof(maxPacketSize);
    OSStatus status;
    
    status = AudioConverterGetProperty(_encodeConvertRef,
                                       kAudioConverterPropertyMaximumOutputPacketSize,
                                       &size,
                                       &maxPacketSize);
    
    AudioBufferList *bufferList             = (AudioBufferList *)malloc(sizeof(AudioBufferList));
    bufferList->mNumberBuffers              = 1;
    bufferList->mBuffers[0].mNumberChannels = _targetDes.mChannelsPerFrame;
    bufferList->mBuffers[0].mData           = malloc(maxPacketSize);
    bufferList->mBuffers[0].mDataByteSize   = kPCMMaxBuffSize;
    
    AudioStreamPacketDescription outputPacketDescriptions;
    
    // inNumPackets设置为1表示编码产生1帧数据即返回，官方：On entry, the capacity of outOutputData expressed in packets in the converter's output format. On exit, the number of packets of converted data that were written to outOutputData. 在输入表示输出数据的最大容纳能力 在转换器的输出格式上，在转换完成时表示多少个包被写入
    UInt32 inNumPackets = 1;
    // inNumPackets设置为1表示编码产生1024帧数据即返回
    // Notice : Here, due to encoder characteristics, 1024 frames of data must be given to the encoder in order to complete a conversion, 在此处由于编码器特性,必须给编码器1024帧数据才能完成一次转换,也就是刚刚在采集数据回调中存储的pcm_buffer
    status = AudioConverterFillComplexBuffer(_encodeConvertRef,
                                             encodeConverterComplexInputDataProc,
                                             pcm_buffer,
                                             &inNumPackets,
                                             bufferList,
                                             &outputPacketDescriptions);
    if(status != noErr){
        free(bufferList->mBuffers[0].mData);
        free(bufferList);
        return NULL;
    }
    NSData *data=nil;
    if (status == 0) {
        NSData *rawAAC = [NSData dataWithBytes:bufferList->mBuffers[0].mData length:bufferList->mBuffers[0].mDataByteSize];
        NSData *adtsHeader = [recoder adtsDataForPacketLength:rawAAC.length];
        NSMutableData *fullData = [NSMutableData dataWithData:adtsHeader];
        [fullData appendData:rawAAC];
        data = fullData;
        if ([recoder.delegate respondsToSelector:@selector(audioSessionBackData:)]) {
            [recoder.delegate audioSessionBackData:data];
        }
    } else {
        
    }
    return bufferList;
}


OSStatus encodeConverterComplexInputDataProc(AudioConverterRef              inAudioConverter,
                                             UInt32                         *ioNumberDataPackets,
                                             AudioBufferList                *ioData,
                                             AudioStreamPacketDescription   **outDataPacketDescription,
                                             void                           *inUserData) {
    
    ioData->mBuffers[0].mData           = inUserData;
    ioData->mBuffers[0].mNumberChannels = _targetDes.mChannelsPerFrame;
    ioData->mBuffers[0].mDataByteSize   = 1024 * 2 * _targetDes.mChannelsPerFrame;
    
    return 0;
}

- (NSData*) adtsDataForPacketLength:(NSUInteger)packetLength {
    int adtsLength = 7;
    char *packet = malloc(sizeof(char) * adtsLength);
    // Variables Recycled by addADTStoPacket
    int profile = 2;  //AAC LC
    //39=MediaCodecInfo.CodecProfileLevel.AACObjectELD;
    int freqIdx = 4;  //44.1KHz
    int chanCfg = 1;  //MPEG-4 Audio Channel Configuration. 1 Channel front-center
    NSUInteger fullLength = adtsLength + packetLength;
    // fill in ADTS data
    packet[0] = (char)0xFF; // 11111111     = syncword
    packet[1] = (char)0xF9; // 1111 1 00 1  = syncword MPEG-2 Layer CRC
    packet[2] = (char)(((profile-1)<<6) + (freqIdx<<2) +(chanCfg>>2));
    packet[3] = (char)(((chanCfg&3)<<6) + (fullLength>>11));
    packet[4] = (char)((fullLength&0x7FF) >> 3);
    packet[5] = (char)(((fullLength&7)<<5) + 0x1F);
    packet[6] = (char)0xFC;
    NSData *data = [NSData dataWithBytesNoCopy:packet length:adtsLength freeWhenDone:YES];
    return data;
}

void caculate_bm_db(void * const data ,size_t length ,int64_t timestamp, enum ChannelCount channelModel,float channelValue[2],bool isAudioUnit) {
    int16_t *audioData = (int16_t *)data;
    
    if (channelModel == k_Mono) {
        int     sDbChnnel     = 0;
        int16_t curr          = 0;
        int16_t max           = 0;
        size_t traversalTimes = 0;
        
        if (isAudioUnit) {
            traversalTimes = length/2;// 由于512后面的数据显示异常  需要全部忽略掉
        }else{
            traversalTimes = length;
        }
        
        for(int i = 0; i< traversalTimes; i++) {
            curr = *(audioData+i);
            if(curr > max) max = curr;
        }
        
        if(max < 1) {
            sDbChnnel = -100;
        }else {
            sDbChnnel = (20*log10((0.0 + max)/32767) - 0.5);
        }
        
        channelValue[0] = channelValue[1] = sDbChnnel;
        
    } else if (channelModel == k_Stereo){
        int sDbChA = 0;
        int sDbChB = 0;
        
        int16_t nCurr[2] = {0};
        int16_t nMax[2] = {0};
        
        for(unsigned int i=0; i<length/2; i++) {
            nCurr[0] = audioData[i];
            nCurr[1] = audioData[i + 1];
            
            if(nMax[0] < nCurr[0]) nMax[0] = nCurr[0];
            
            if(nMax[1] < nCurr[1]) nMax[1] = nCurr[0];
        }
        
        if(nMax[0] < 1) {
            sDbChA = -100;
        } else {
            sDbChA = (20*log10((0.0 + nMax[0])/32767) - 0.5);
        }
        
        if(nMax[1] < 1) {
            sDbChB = -100;
        } else {
            sDbChB = (20*log10((0.0 + nMax[1])/32767) - 0.5);
        }
        
        channelValue[0] = sDbChA;
        channelValue[1] = sDbChB;
    }
}


#pragma mark - AudioUnit

- (void)startAudioUnitRecorder {
    OSStatus status;
    [self initGlobalVar];
    status = AudioOutputUnitStart(_audioUnit);
    NSLog(@"AudioOutputUnitStart status : %d \n",status);
    if (status == noErr) {
    }
}

- (void)stopAudioUnitRecorder{
     OSStatus status = AudioOutputUnitStop(_audioUnit);
    if (status == noErr) {
    }
}
@end
