////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMTestCase.h"

#import "RLMRealmConfiguration_Private.h"
#import <Realm/RLMRealm_Private.h>
#import <Realm/RLMSchema_Private.h>
#import <Realm/RLMRealmConfiguration_Private.h>

static NSString *parentProcessBundleIdentifier()
{
    static BOOL hasInitializedIdentifier;
    static NSString *identifier;
    if (!hasInitializedIdentifier) {
        identifier = [NSProcessInfo processInfo].environment[@"RLMParentProcessBundleID"];
        hasInitializedIdentifier = YES;
    }

    return identifier;
}

NSString *RLMDefaultRealmPath() {
    return RLMRealmPathForFileAndBundleIdentifier(@"default.realm", parentProcessBundleIdentifier());
}

NSString *RLMTestRealmPath() {
    return RLMRealmPathForFileAndBundleIdentifier(@"test.realm", parentProcessBundleIdentifier());
}

static void deleteOrThrow(NSString *path) {
    NSError *error;
    if (![[NSFileManager defaultManager] removeItemAtPath:path error:&error]) {
        if (error.code != NSFileNoSuchFileError) {
            @throw [NSException exceptionWithName:@"RLMTestException"
                                           reason:[@"Unable to delete realm: " stringByAppendingString:error.description]
                                         userInfo:nil];
        }
    }
}

NSData *RLMGenerateKey() {
    uint8_t buffer[64];
    SecRandomCopyBytes(kSecRandomDefault, 64, buffer);
    return [[NSData alloc] initWithBytes:buffer length:sizeof(buffer)];
}

static BOOL encryptTests() {
    static BOOL encryptAll = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (getenv("REALM_ENCRYPT_ALL")) {
            encryptAll = YES;
        }
    });
    return encryptAll;
}

@implementation RLMTestCase {
    dispatch_queue_t _bgQueue;
}

+ (void)setUp {
    [super setUp];
#if DEBUG || !TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
    // Disable actually syncing anything to the disk to greatly speed up the
    // tests, but only when not running on device because it can't be
    // re-enabled and we need it enabled for performance tests
    RLMDisableSyncToDisk();
#endif
    [self preintializeSchema];

    if (!getenv("RLMProcessIsChild")) {
        // Clean up any potentially lingering Realm files from previous runs
        [NSFileManager.defaultManager removeItemAtPath:RLMRealmPathForFile(@"") error:nil];
    }

    // Ensure the documents directory exists as it sometimes doesn't after
    // resetting the simulator
    [NSFileManager.defaultManager createDirectoryAtPath:RLMDefaultRealmPath().stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)setUp {
    @autoreleasepool {
        [super setUp];
        [self deleteFiles];

        if (encryptTests()) {
            RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
            configuration.encryptionKey = RLMGenerateKey();
        }
    }
}

- (void)tearDown {
    @autoreleasepool {
        [super tearDown];
        if (_bgQueue) {
            dispatch_sync(_bgQueue, ^{});
            _bgQueue = nil;
        }
        [self deleteFiles];
    }
}

// This ensures the shared schema is initialized outside of of a test case,
// so if an exception is thrown, it will kill the test process rather than
// allowing hundreds of test cases to fail in strange ways
// This is overridden by RLMMultiProcessTestCase to support testing the schema init
+ (void)preintializeSchema {
    [RLMSchema sharedSchema];
}

- (void)deleteFiles {
    // Clear cache
    [self resetRealmState];

    // Delete Realm files
    [self deleteRealmFileAtPath:RLMDefaultRealmPath()];
    [self deleteRealmFileAtPath:RLMTestRealmPath()];
}

- (void)resetRealmState {
    [RLMRealm resetRealmState];
}

- (void)deleteRealmFileAtPath:(NSString *)path
{
    deleteOrThrow(path);
    deleteOrThrow([path stringByAppendingString:@".lock"]);
    deleteOrThrow([path stringByAppendingString:@".note"]);
}

- (void)invokeTest {
    @autoreleasepool {
        [super invokeTest];
    }
}

- (RLMRealm *)realmWithTestPath
{
    return [RLMRealm realmWithPath:RLMTestRealmPath()];
}

- (RLMRealm *)realmWithTestPathAndSchema:(RLMSchema *)schema {
    return [RLMRealm realmWithPath:RLMTestRealmPath() key:nil readOnly:NO inMemory:NO dynamic:YES schema:schema error:nil];
}

- (RLMRealm *)inMemoryRealmWithIdentifier:(NSString *)identifier {
    RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
    configuration.inMemoryIdentifier = identifier;
    return [RLMRealm realmWithConfiguration:configuration error:nil];
}

- (RLMRealm *)readOnlyRealmWithPath:(NSString *)path error:(NSError **)error {
    RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
    configuration.path = path;
    configuration.readOnly = true;
    return [RLMRealm realmWithConfiguration:configuration error:error];
}

- (void)waitForNotification:(NSString *)expectedNote realm:(RLMRealm *)realm block:(dispatch_block_t)block {
    XCTestExpectation *notificationFired = [self expectationWithDescription:@"notification fired"];
    RLMNotificationToken *token = [realm addNotificationBlock:^(NSString *note, RLMRealm *realm) {
        XCTAssertNotNil(note, @"Note should not be nil");
        XCTAssertNotNil(realm, @"Realm should not be nil");
        if (note == expectedNote) { // Check pointer equality to ensure we're using the interned string constant
            [notificationFired fulfill];
        }
    }];

    dispatch_queue_t queue = dispatch_queue_create("background", 0);
    dispatch_async(queue, ^{
        @autoreleasepool {
            block();
        }
    });

    [self waitForExpectationsWithTimeout:2.0 handler:nil];

    // wait for queue to finish
    dispatch_sync(queue, ^{});

    [realm removeNotification:token];
}

- (void)dispatchAsync:(dispatch_block_t)block {
    if (!_bgQueue) {
        _bgQueue = dispatch_queue_create("test background queue", 0);
    }
    dispatch_async(_bgQueue, ^{
        @autoreleasepool {
            block();
        }
    });
}

- (void)dispatchAsyncAndWait:(dispatch_block_t)block {
    [self dispatchAsync:block];
    dispatch_sync(_bgQueue, ^{});
}

- (id)nonLiteralNil
{
    return nil;
}

@end

