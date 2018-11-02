//
//  CMAudioSession.h
//  CMSocketServer
//
//  Created by coldMountain on 2018/10/16.
//  Copyright © 2018 ColdMountain. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@protocol CMAudioSessionDelegate <NSObject>

- (void)audioSessionBackData:(NSData*)audioData;

@end


@interface CMAudioSession : NSObject

- (void)startAudioUnitRecorder;

- (void)stopAudioUnitRecorder;

@property (nonatomic, assign) id<CMAudioSessionDelegate>delegate;
@end

