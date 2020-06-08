@import Foundation;

#import "MGLMapboxEvents.h"
#import "MBXSKUToken.h"
#import "NSBundle+MGLAdditions.h"
#import "MGLAccountManager_Private.h"

// NSUserDefaults and Info.plist keys
NSString * const MGLMapboxMetricsEnabledKey = @"MGLMapboxMetricsEnabled";
static NSString * const MGLMapboxMetricsDebugLoggingEnabledKey = @"MGLMapboxMetricsDebugLoggingEnabled";
static NSString * const MGLMapboxMetricsEnabledSettingShownInAppKey = @"MGLMapboxMetricsEnabledSettingShownInApp";
static NSString * const MGLTelemetryAccessTokenKey = @"MGLTelemetryAccessToken";
static NSString * const MGLTelemetryBaseURLKey = @"MGLTelemetryBaseURL";

static NSString * const MGLAPIClientUserAgentBase = @"mapbox-maps-ios";

static void * MGLMapboxMetricsEnabledKeyContext = &MGLMapboxMetricsEnabledKeyContext;
static void * MGLMapboxMetricsDebugLoggingEnabledKeyContext = &MGLMapboxMetricsDebugLoggingEnabledKeyContext;
static void * MGLTelemetryAccessTokenKeyContext = &MGLTelemetryAccessTokenKeyContext;

@interface MGLMapboxEvents ()

@property (nonatomic) MMEEventsManager *eventsManager;
@property (nonatomic) NSURL *baseURL;
@property (nonatomic, copy) NSString *accessToken;

// Readonly Reference to MMEEvents UserDefaults reference
@property (nonatomic, readonly) NSUserDefaults *userDefaults;

@end

@implementation MGLMapboxEvents

+ (void)initialize {
    if (self == [MGLMapboxEvents class]) {
        NSBundle *bundle = [NSBundle mainBundle];
        NSNumber *accountTypeNumber = [bundle objectForInfoDictionaryKey:MGLMapboxAccountTypeKey];
        [[self userDefaults] registerDefaults:@{MGLMapboxAccountTypeKey: accountTypeNumber ?: @0,
                                                                  MGLMapboxMetricsEnabledKey: @YES,
                                                                  MGLMapboxMetricsDebugLoggingEnabledKey: @NO}];
    }
}

+ (nullable instancetype)sharedInstance {
    
    static dispatch_once_t onceToken;
    static MGLMapboxEvents *_sharedInstance;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[self alloc] init];
    });
    return _sharedInstance;
}

// Readonly Reference to MMEEvents UserDefaults reference
+ (NSUserDefaults*)userDefaults {
    return MMEEventsManager.sharedManager.configuration.userDefaults;
}

- (NSUserDefaults*)userDefaults {
    return [self.class userDefaults];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _eventsManager = MMEEventsManager.sharedManager;


        if ([[NSUserDefaults standardUserDefaults] boolForKey :MGLMapboxMetricsDebugLoggingEnabledKey]) {
            _eventsManager.logLevel = MMELogInfo;
        } else {
            _eventsManager.logLevel = MMELogNone;
        }


        BOOL collectionEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:MGLMapboxMetricsEnabledKey];
        _eventsManager.configuration.isCollectionEnabled = collectionEnabled;

        // It is possible for the shared instance of this class to be created because of a call to
        // +[MGLAccountManager load] early on in the app lifecycle of the host application.
        // If user default values for access token and base URL are available, they are stored here
        // on local properties so that they can be applied later once MMEEventsManager is fully initialized
        // (once -[MMEEventsManager initializeWithAccessToken:userAgentBase:hostSDKVersion:] is called.
        // Normally, the telem access token and base URL are not set this way. However, overriding these values
        // with user defaults can be useful for testing with an alternative (test) backend system.
        if ([[[[NSUserDefaults standardUserDefaults] dictionaryRepresentation] allKeys] containsObject:MGLTelemetryAccessTokenKey]) {
            self.accessToken = [[NSUserDefaults standardUserDefaults] objectForKey:MGLTelemetryAccessTokenKey];
        }
        if ([[[[NSUserDefaults standardUserDefaults] dictionaryRepresentation] allKeys] containsObject:MGLTelemetryBaseURLKey]) {
            self.baseURL = [NSURL URLWithString:[[NSUserDefaults standardUserDefaults] objectForKey:MGLTelemetryBaseURLKey]];
        }
        
        // Guard against over calling pause / resume if the values this implementation actually
        // cares about have not changed. We guard because the pause and resume method checks CoreLocation's
        // authorization status and that can drag on the main thread if done too many times (e.g. if the host
        // app heavily uses the user defaults API and this method is called very frequently)
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults addObserver:self
                   forKeyPath:MGLMapboxMetricsEnabledKey
                      options:NSKeyValueObservingOptionNew
                      context:MGLMapboxMetricsEnabledKeyContext];
        [defaults addObserver:self
                   forKeyPath:MGLMapboxMetricsDebugLoggingEnabledKey
                      options:NSKeyValueObservingOptionNew
                      context:MGLMapboxMetricsDebugLoggingEnabledKeyContext];
        [defaults addObserver:self
                   forKeyPath:MGLTelemetryAccessTokenKey
                      options:NSKeyValueObservingOptionNew
                      context:MGLTelemetryAccessTokenKeyContext];
    }
    return self;
}

- (void)dealloc {
    @try {

        // TODOD: Do we still need to be monitoring this? Do we need to do it by key?
        // Or perhaps we could expose KVO compliance for each property?
        NSUserDefaults *defaults = self.eventsManager.configuration.userDefaults;

        [defaults removeObserver:self forKeyPath:MGLMapboxMetricsEnabledKey];
        [defaults removeObserver:self forKeyPath:MGLMapboxMetricsDebugLoggingEnabledKey];
        [defaults removeObserver:self forKeyPath:MGLTelemetryAccessTokenKey];
    }
    @catch (NSException *exception) {
        [self.eventsManager reportException:exception];
    } //If the observer is removed by a superclass this may fail since we are removing it twice.
}

// TODO: Why are we observing these items?
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    //KVO callback can happen on any thread. Even two threads concurrently for the same key.
    if (context == MGLMapboxMetricsEnabledKeyContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateDisablingConfigurationValues];
        });
    } else if (context == MGLMapboxMetricsDebugLoggingEnabledKeyContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([[NSUserDefaults standardUserDefaults] boolForKey :MGLMapboxMetricsDebugLoggingEnabledKey]) {
                self.eventsManager.logLevel = MMELogInfo;
            } else {
                self.eventsManager.logLevel = MMELogNone;
            }
        });
    } else if (context == MGLTelemetryAccessTokenKeyContext) {
       dispatch_async(dispatch_get_main_queue(), ^{
           [self updateNonDisablingConfigurationValues];
       });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)updateNonDisablingConfigurationValues {
    if ([[[[NSUserDefaults standardUserDefaults] dictionaryRepresentation] allKeys] containsObject:MGLTelemetryAccessTokenKey]) {
        NSString *telemetryAccessToken = [[NSUserDefaults standardUserDefaults] objectForKey:MGLTelemetryAccessTokenKey];
        self.eventsManager.configuration.accessToken = telemetryAccessToken;
    }
}

- (void)updateDisablingConfigurationValues {
    BOOL collectionEnabled = [NSUserDefaults.standardUserDefaults boolForKey:MGLMapboxMetricsEnabledKey];
    self.eventsManager.configuration.isCollectionEnabled = collectionEnabled;
    [self.eventsManager pauseOrResumeMetricsCollectionIfRequired];
}

+ (void)setupWithAccessToken:(NSString *)accessToken {

    MGLMapboxEvents *events = [MGLMapboxEvents sharedInstance];

    // From https://github.com/mapbox/mapbox-events-ios
    NSString *semanticVersion = [NSBundle mgl_frameworkInfoDictionary][@"MGLSemanticVersionString"];
    NSString *shortVersion = [NSBundle mgl_frameworkInfoDictionary][@"CFBundleShortVersionString"];
    NSString *sdkVersion = semanticVersion ?: shortVersion;

    MMEEventsManager *eventsManager = MMEEventsManager.sharedManager;

    // It is possible that an alternative access token was already set on this instance when the class was loaded
    // Use it if it exists
    NSString *resolvedAccessToken = [MGLMapboxEvents sharedInstance].accessToken ?: accessToken;
    [eventsManager startEventsManagerWithToken:resolvedAccessToken
                                 userAgentBase:MGLAPIClientUserAgentBase
                                hostSDKVersion:sdkVersion];
    [eventsManager startEventsManagerWithToken:resolvedAccessToken];

    eventsManager.skuId                       = MBXAccountsSKUIDMapsUser;

    if ([[NSUserDefaults standardUserDefaults] boolForKey :MGLMapboxMetricsDebugLoggingEnabledKey]) {
        eventsManager.logLevel = MMELogInfo;
    } else {
        eventsManager.logLevel = MMELogNone;
    }

    events.eventsManager = eventsManager;
}

+ (void)pushTurnstileEvent {
    [[[self sharedInstance] eventsManager] sendTurnstileEvent];
}

+ (void)pushEvent:(NSString *)event withAttributes:(MMEMapboxEventAttributes *)attributeDictionary {
    [[[self sharedInstance] eventsManager] enqueueEventWithName:event attributes:attributeDictionary];
}

+ (void)flush {
    [[[self sharedInstance] eventsManager] flush];
}

+ (void)ensureMetricsOptoutExists {
    NSNumber *shownInAppNumber = [[NSBundle mainBundle] objectForInfoDictionaryKey:MGLMapboxMetricsEnabledSettingShownInAppKey];
    BOOL metricsEnabledSettingShownInAppFlag = [shownInAppNumber boolValue];

    if (!metricsEnabledSettingShownInAppFlag &&
        [self.userDefaults integerForKey:MGLMapboxAccountTypeKey] == 0) {
        // Opt-out is not configured in UI, so check for Settings.bundle
        BOOL defaultEnabledValue = NO;
        NSString *appSettingsBundle = [[NSBundle mainBundle] pathForResource:@"Settings" ofType:@"bundle"];
        
        if (appSettingsBundle) {
            // Dynamic Settings.bundle loading based on http://stackoverflow.com/a/510329/2094275
            NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[appSettingsBundle stringByAppendingPathComponent:@"Root.plist"]];
            NSArray *preferences = settings[@"PreferenceSpecifiers"];
            for (NSDictionary *prefSpecification in preferences) {
                if ([prefSpecification[@"Key"] isEqualToString:MGLMapboxMetricsEnabledKey]) {
                    NSNumber *defaultValue = prefSpecification[@"DefaultValue"];
                    defaultEnabledValue = [defaultValue boolValue];
                }
            }
        }
        
        if (!defaultEnabledValue) {
            [NSException raise:@"Telemetry opt-out missing" format:
             @"End users must be able to opt out of Mapbox Telemetry in your app, either inside Settings (via Settings.bundle) or inside this app. "
             @"By default, this opt-out control is included as a menu item in the attribution action sheet. "
             @"If you reimplement the opt-out control inside this app, disable this assertion by setting MGLMapboxMetricsEnabledSettingShownInApp to YES in Info.plist."
             @"\n\nSee https://docs.mapbox.com/help/how-mapbox-works/attribution/#mapbox-maps-sdk-for-ios for more information."
             @"\n\nAdditionally, by hiding this attribution control you agree to display the required attribution elsewhere in this app."];
        }
    }
}

@end
