/*
 * Copyright (c) 2017, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import <Foundation/Foundation.h>
#import <PsiphonTunnel/PsiphonTunnel.h>
#import "FeedbackUpload.h"
#import "LogViewControllerFullScreen.h"
#import "PsiphonConfigUserDefaults.h"
#import "PsiphonClientCommonLibraryHelpers.h"
#import "PsiphonDataSharedDB.h"
#import "RegionAdapter.h"
#import "RegionSelectionViewController.h"
#import "SharedConstants.h"
#import "Notifier.h"
#import "UIImage+CountryFlag.h"
#import "UpstreamProxySettings.h"
#import "MainViewController.h"
#import "VPNManager.h"
#import "AdManager.h"
#import "PulsingHaloLayer.h"
#import "Logging.h"
#import "IAPViewController.h"
#import "AppDelegate.h"
#import "IAPHelper.h"

static BOOL (^safeStringsEqual)(NSString *, NSString *) = ^BOOL(NSString *a, NSString *b) {
    return (([a length] == 0) && ([b length] == 0)) || ([a isEqualToString:b]);
};

@interface MainViewController ()
@end

@implementation MainViewController {

    // VPN Manager
    VPNManager *vpnManager;

    AdManager *adManager;

    PsiphonDataSharedDB *sharedDB;

    // Notifier
    Notifier *notifier;

    // UI elements
    //UIImageView *logoView;
    UILabel *appTitleLabel;
    UILabel *appSubTitleLabel;
    UILabel *statusLabel;
    UILabel *versionLabel;
	UIButton *subscriptionButton;
    UILabel *regionButtonHeader;
    UIButton *regionButton;
    UIButton *startStopButton;
    PulsingHaloLayer *startStopButtonHalo;
    BOOL isStartStopButtonHaloOn;

    // UI Constraint
    NSLayoutConstraint *startButtonScreenWidth;
    NSLayoutConstraint *startButtonScreenHeight;
    NSLayoutConstraint *startButtonWidth;

    // UI Layer
    CAGradientLayer *backgroundGradient;

    // VPN Config user defaults
    PsiphonConfigUserDefaults *psiphonConfigUserDefaults;

    // Settings
    PsiphonSettingsViewController *appSettingsViewController;
    UIButton *settingsButton;

    // Region Selection
    UINavigationController *regionSelectionNavController;
    UIView *bottomBar;
    NSString *selectedRegionSnapShot;

    UIAlertController *alert;
}

- (id)init {
    self = [super init];
    if (self) {
        vpnManager = [VPNManager sharedInstance];

        adManager = [AdManager sharedInstance];

        sharedDB = [[PsiphonDataSharedDB alloc] initForAppGroupIdentifier:APP_GROUP_IDENTIFIER];

        // Notifier
        notifier = [[Notifier alloc] initWithAppGroupIdentifier:APP_GROUP_IDENTIFIER];

        // VPN Config user defaults
        psiphonConfigUserDefaults = [PsiphonConfigUserDefaults sharedInstance];
        [self persistSettingsToSharedUserDefaults];

        // Open Setting after change it
        self.openSettingImmediatelyOnViewDidAppear = NO;
    }
    return self;
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Lifecycle methods
- (void)viewDidLoad {
   LOG_DEBUG();
    [super viewDidLoad];

    // TODO: check if database exists first
    BOOL success = [sharedDB createDatabase];
    if (!success) {
        // TODO : do some error handling
    }

    // Add any available regions from shared db to region adapter
    [self updateAvailableRegions];

    // Setting up the UI
    [self setBackgroundGradient];
    [self setNeedsStatusBarAppearanceUpdate];
    //  TODO: wrap this in a function which always
    //  calls them in the right order
    [self addSettingsButton];
	[self addRegionSelectionBar];
    [self addStartAndStopButton];
	[self addAppTitleLabel];
	[self addAppSubTitleLabel];
	[self addSubscriptionButton];
    [self addStatusLabel];
    [self addVersionLabel];
    //[self addLogoImage];

    if (([[UIDevice currentDevice].model hasPrefix:@"iPhone"] || [[UIDevice currentDevice].model hasPrefix:@"iPod"]) && (self.view.bounds.size.width > self.view.bounds.size.height)) {
        //logoView.hidden = YES;
        //appTitleLabel.hidden = YES;
        //appSubTitleLabel.hidden = YES;
    }

    [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(onVPNStatusDidChange) name:@kVPNStatusChangeNotificationName object:vpnManager];

	// Observe IAP transaction notification
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(updatedIAPTransactionState)
												 name:kIAPSKPaymentTransactionStatePurchased
											   object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(updatedIAPTransactionState)
												 name:kIAPSKPaymentTransactionStateRestored
											   object:nil];



    // TODO: load/save config here to have the user immediately complete the permission prompt
}

- (void)viewDidAppear:(BOOL)animated {
   LOG_DEBUG();
    [super viewDidAppear:animated];
    // Available regions may have changed in the background
    [self updateAvailableRegions];
    [self updateRegionButton];

    if (self.openSettingImmediatelyOnViewDidAppear) {
        [self openSettingsMenu];
        self.openSettingImmediatelyOnViewDidAppear = NO;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    backgroundGradient.frame = self.view.bounds;
}

- (void)viewWillAppear:(BOOL)animated {
   LOG_DEBUG();
    [super viewWillAppear:animated];

    // Listen for VPN status changes from VPNManager.

    // Sync UI with the VPN state
    [self onVPNStatusDidChange];
}

- (void)viewWillDisappear:(BOOL)animated {
   LOG_DEBUG();
    [super viewWillDisappear:animated];
    // Stop listening for diagnostic messages (we don't want to hold the shared db lock while backgrounded)
    [notifier stopListeningForAllNotifications];
}

- (void)viewDidDisappear:(BOOL)animated {
   LOG_DEBUG();
    [super viewDidDisappear:animated];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

// Reload when rotate
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self.view removeConstraint:startButtonWidth];
	[self setRegionSelectionConstraints:size];

    if (size.width > size.height) {
        [self.view removeConstraint:startButtonScreenWidth];
        [self.view addConstraint:startButtonScreenHeight];
        regionButtonHeader.hidden = YES;
        if ([[UIDevice currentDevice].model hasPrefix:@"iPhone"]) {
            //logoView.hidden = YES;
            //appTitleLabel.hidden = YES;
            //appSubTitleLabel.hidden = YES;
        }
    } else {
        [self.view removeConstraint:startButtonScreenHeight];
        [self.view addConstraint:startButtonScreenWidth];
        regionButtonHeader.hidden = NO;
        if ([[UIDevice currentDevice].model hasPrefix:@"iPhone"]) {
            //logoView.hidden = NO;
            //appTitleLabel.hidden = NO;
            //appSubTitleLabel.hidden = NO;
        }
    }

    [self.view addConstraint:startButtonWidth];

    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (isStartStopButtonHaloOn && startStopButtonHalo) {
            startStopButtonHalo.hidden = YES;
        }
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (isStartStopButtonHaloOn && startStopButtonHalo) {
            startStopButtonHalo.hidden = NO;
        }
    }];

    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

#pragma mark - UI callbacks

- (void)onVPNStatusDidChange {
    // Update UI
    VPNStatus s = [vpnManager getVPNStatus];
    [self updateButtonState];
    statusLabel.text = [self getVPNStatusDescription:s];

    if (s == VPNStatusConnecting || s == VPNStatusRestarting || s == VPNStatusReasserting) {
        [self addPulsingHaloLayer];
    } else {
        [self removePulsingHaloLayer];
    }

    // Notify SettingsViewController that the state has changed
    [[NSNotificationCenter defaultCenter] postNotificationName:kPsiphonConnectionStateNotification object:nil];
}

- (void)onStartStopTap:(UIButton *)sender {

    if (![vpnManager isVPNActive]) {

        // Alerts the user if there is no internet connection.
        Reachability *reachability = [Reachability reachabilityForInternetConnection];
        if ([reachability currentReachabilityStatus] == NotReachable) {
            [self displayAlertNoInternet];
        } else {
            [adManager showUntunneledInterstitial];
        }

    } else {
       LOG_DEBUG(@"call [vpnManager stopVPN]");
        [vpnManager stopVPN];

        [self removePulsingHaloLayer];
    }
}

- (void)onSettingsButtonTap:(UIButton *)sender {
    [self openSettingsMenu];
}

- (void)onRegionButtonTap:(UIButton *)sender {
    [self openRegionSelection];
}

- (void) onSubscriptionTap {
	[self openIAPViewController];
}

#if DEBUG
- (void)onVersionLabelTap:(UILabel *)sender {
    LogViewControllerFullScreen *log = [[LogViewControllerFullScreen alloc] init];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:log];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    nav.modalTransitionStyle = UIModalTransitionStyleCoverVertical;

    [self presentViewController:nav animated:YES completion:nil];
}
#endif

# pragma mark - UI helper functions
- (void) dismissNoInternetAlert {
    LOG_DEBUG();
    if (alert != nil){
        [alert dismissViewControllerAnimated:YES completion:nil];
        alert = nil;
    }
}

- (void)displayAlertNoInternet {
    if (alert == nil){
        alert = [UIAlertController
          alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"NO_INTERNET", nil, [NSBundle mainBundle], @"No Internet Connection", @"Alert title informing user there is no internet connection")
                           message:NSLocalizedStringWithDefaultValue(@"TURN_ON_DATE", nil, [NSBundle mainBundle], @"Turn on cellular data or use Wi-Fi to access data.", @"Alert message informing user to turn on their cellular data or wifi to connect to the internet")
                    preferredStyle:UIAlertControllerStyleAlert];

        UIAlertAction *defaultAction = [UIAlertAction
          actionWithTitle:NSLocalizedStringWithDefaultValue(@"OK_BUTTON", nil, [NSBundle mainBundle], @"OK", @"Alert OK Button")
                    style:UIAlertActionStyleDefault
                  handler:^(UIAlertAction *action) {
                  }];

        [alert addAction:defaultAction];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dismissNoInternetAlert) name:@"UIApplicationWillResignActiveNotification" object:nil];
    }

    [self presentViewController:alert animated:TRUE completion:nil];
}

- (NSString *)getVPNStatusDescription:(VPNStatus) status {
    switch(status) {
        case VPNStatusDisconnected: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_DISCONNECTED", nil, [NSBundle mainBundle], @"Disconnected", @"Status when the VPN is not connected to a Psiphon server, not trying to connect, and not in an error state");
        case VPNStatusInvalid: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_INVALID", nil, [NSBundle mainBundle], @"Disconnected", @"Status when the VPN is in an invalid state. For example, if the user doesn't give permission for the VPN configuration to be installed, and therefore the Psiphon VPN can't even try to connect.");
        case VPNStatusConnected: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_CONNECTED", nil, [NSBundle mainBundle], @"Connected", @"Status when the VPN is connected to a Psiphon server");
        case VPNStatusConnecting: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_CONNECTING", nil, [NSBundle mainBundle], @"Connecting", @"Status when the VPN is connecting; that is, trying to connect to a Psiphon server");
        case VPNStatusDisconnecting: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_DISCONNECTING", nil, [NSBundle mainBundle], @"Disconnecting", @"Status when the VPN is disconnecting. Sometimes going from connected to disconnected can take some time, and this is that state.");
        case VPNStatusReasserting: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_RECONNECTING", nil, [NSBundle mainBundle], @"Reconnecting", @"Status when the VPN was connected to a Psiphon server, got disconnected unexpectedly, and is currently trying to reconnect");
        case VPNStatusRestarting: return NSLocalizedStringWithDefaultValue(@"VPN_STATUS_RESTARTING", nil, [NSBundle mainBundle], @"Restarting", @"Status when the VPN is restarting.");
    }
    return nil;
}

- (void)setBackgroundGradient {
    backgroundGradient = [CAGradientLayer layer];
    
    backgroundGradient.colors = @[(id)[UIColor colorWithRed:0.17 green:0.17 blue:0.28 alpha:1.0].CGColor, (id)[UIColor colorWithRed:0.28 green:0.36 blue:0.46 alpha:1.0].CGColor];

    [self.view.layer insertSublayer:backgroundGradient atIndex:0];
}

- (void)addPulsingHaloLayer {
    // Don't add multiple layers
    if (isStartStopButtonHaloOn) {
        return;
    }
    isStartStopButtonHaloOn = TRUE;
    
    CGFloat radius = (CGFloat) (MIN(self.view.frame.size.width, self.view.frame.size.height) / 2.5);

    startStopButtonHalo = [PulsingHaloLayer layer];
    startStopButtonHalo.position = startStopButton.center;
    startStopButtonHalo.radius = radius;
    startStopButtonHalo.backgroundColor =
      [UIColor colorWithRed:0.44 green:0.51 blue:0.58 alpha:1.0].CGColor;
    startStopButtonHalo.haloLayerNumber = 3;

    [self.view.layer insertSublayer:startStopButtonHalo below:startStopButton.layer];

    [startStopButtonHalo start];
}

- (void)removePulsingHaloLayer {
    [startStopButtonHalo stop];
    
    isStartStopButtonHaloOn = FALSE;
}

- (BOOL) isRightToLeft {
    return ([UIApplication sharedApplication].userInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft);
}

/*- (void)addLogoImage {
    logoView = [[UIImageView alloc] init];
    [logoView setImage:[UIImage imageNamed:@"Logo"]];
    [logoView setTranslatesAutoresizingMaskIntoConstraints:NO];

    [self.view addSubview:logoView];

    // Setup autolayout
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:logoView
                                                          attribute:NSLayoutAttributeTop
                                                          relatedBy:NSLayoutRelationGreaterThanOrEqual
                                                             toItem:self.topLayoutGuide
                                                          attribute:NSLayoutAttributeBottom
                                                         multiplier:1.0
                                                           constant:30]];

    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:logoView
                                                          attribute:NSLayoutAttributeCenterX
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeCenterX
                                                         multiplier:1.0
                                                           constant:0]];
}*/

- (BOOL)unsupportedCharactersForFont:(NSString*)font withString:(NSString*)string {
    for (NSInteger charIdx = 0; charIdx < string.length; charIdx++) {
        NSString *character = [NSString stringWithFormat:@"%C", [string characterAtIndex:charIdx]];
        // TODO: need to enumerate a longer list of special characters for this to be more correct.
        if ([character isEqualToString:@" "]) {
            // Skip special characters
            continue;
        }
        CGFontRef cgFont = CGFontCreateWithFontName((CFStringRef)font);
        BOOL unsupported = (CGFontGetGlyphWithGlyphName(cgFont,  (__bridge CFStringRef)character) == 0);
        CGFontRelease(cgFont);
        if (unsupported) {
            return YES;
        }
    }
    return NO;
}

- (void)addAppTitleLabel {
    appTitleLabel = [[UILabel alloc] init];
    appTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    appTitleLabel.text = NSLocalizedStringWithDefaultValue(@"APP_TITLE_MAIN_VIEW", nil, [NSBundle mainBundle], @"PSIPHON", @"Text for app title on main view.");
    appTitleLabel.textAlignment = NSTextAlignmentCenter;
    appTitleLabel.textColor = [UIColor whiteColor];
    int narrowestWidth = self.view.frame.size.width;
    if (self.view.frame.size.height < self.view.frame.size.width) {
        narrowestWidth = self.view.frame.size.height;
    }
    appTitleLabel.font = [UIFont fontWithName:@"Bourbon-Oblique" size:narrowestWidth * 0.10625f];
    if ([self unsupportedCharactersForFont:appTitleLabel.font.fontName withString:appTitleLabel.text]) {
        appTitleLabel.font = [UIFont systemFontOfSize:narrowestWidth * 0.075f];
    }

    [self.view addSubview:appTitleLabel];
    
    // Setup autolayout
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:appTitleLabel
                                                          attribute:NSLayoutAttributeTop
                                                          relatedBy:NSLayoutRelationLessThanOrEqual
                                                             toItem:self.topLayoutGuide
                                                          attribute:NSLayoutAttributeBottom
                                                         multiplier:1.0
                                                           constant:0]];
    
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:appTitleLabel
                                                          attribute:NSLayoutAttributeCenterX
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeCenterX
                                                         multiplier:1.0
                                                           constant:0.0]];
}

- (void)addAppSubTitleLabel {
    appSubTitleLabel = [[UILabel alloc] init];
    appSubTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    appSubTitleLabel.text = NSLocalizedStringWithDefaultValue(@"APP_SUB_TITLE_MAIN_VIEW", nil, [NSBundle mainBundle], @"BEYOND BORDERS", @"Text for app subtitle on main view.");
    appSubTitleLabel.textAlignment = NSTextAlignmentCenter;
    appSubTitleLabel.textColor = [UIColor whiteColor];
    int narrowestWidth = self.view.frame.size.width;
    if (self.view.frame.size.height < self.view.frame.size.width) {
        narrowestWidth = self.view.frame.size.height;
    }
    appSubTitleLabel.font = [UIFont fontWithName:@"Bourbon-Oblique" size:narrowestWidth * 0.10625f/2.0f];
    if ([self unsupportedCharactersForFont:appSubTitleLabel.font.fontName withString:appSubTitleLabel.text]) {
        appSubTitleLabel.font = [UIFont systemFontOfSize:narrowestWidth * 0.075f/2.0f];
    }

    [self.view addSubview:appSubTitleLabel];
    
    // Setup autolayout
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:appSubTitleLabel
                                                          attribute:NSLayoutAttributeTop
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:appTitleLabel
                                                          attribute:NSLayoutAttributeBottom
                                                         multiplier:1.0
                                                           constant:0]];

	[self.view addConstraint:[NSLayoutConstraint constraintWithItem:appSubTitleLabel
                                                          attribute:NSLayoutAttributeLeft
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeLeft
                                                         multiplier:1.0
                                                           constant:15.0]];
    
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:appSubTitleLabel
                                                          attribute:NSLayoutAttributeRight
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeRight
                                                         multiplier:1.0
                                                           constant:-15.0]];
}

- (void)addSettingsButton {
    settingsButton = [[UIButton alloc] init];
    UIImage *gearTemplate = [[UIImage imageNamed:@"settings"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [settingsButton setImage:gearTemplate forState:UIControlStateNormal];
    [settingsButton setTintColor:[UIColor whiteColor]];
    [self.view addSubview:settingsButton];

    // Setup autolayout
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:settingsButton
                                                          attribute:NSLayoutAttributeCenterY
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.topLayoutGuide
                                                          attribute:NSLayoutAttributeBottom
                                                         multiplier:1.0
                                                           constant:gearTemplate.size.height/2 + 8.f]];


    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:settingsButton
                                                          attribute:NSLayoutAttributeCenterX
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeTrailing
                                                         multiplier:1.0
                                                           constant:-gearTemplate.size.width/2 - 13.f]];

    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:settingsButton
                                                          attribute:NSLayoutAttributeWidth
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:nil
                                                          attribute:NSLayoutAttributeNotAnAttribute
                                                         multiplier:1.0
                                                           constant:80]];

    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:settingsButton
                                                          attribute:NSLayoutAttributeHeight
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:settingsButton
                                                          attribute:NSLayoutAttributeWidth
                                                         multiplier:1.0
                                                           constant:0.f]];

    [settingsButton addTarget:self action:@selector(onSettingsButtonTap:) forControlEvents:UIControlEventTouchUpInside];
}

- (void)updateButtonState {
    if ([vpnManager isVPNActive] && ![vpnManager isVPNConnected]) {
        UIImage *connectingButtonImage = [UIImage imageNamed:@"ConnectingButton"];
        [startStopButton setImage:connectingButtonImage forState:UIControlStateNormal];
    }
    else if ([vpnManager isVPNConnected]) {
        UIImage *stopButtonImage = [UIImage imageNamed:@"StopButton"];
        [startStopButton setImage:stopButtonImage forState:UIControlStateNormal];
    }
    else {
        UIImage *startButtonImage = [UIImage imageNamed:@"StartButton"];
        [startStopButton setImage:startButtonImage forState:UIControlStateNormal];
    }
}

- (void)addStartAndStopButton {
    startStopButton = [UIButton buttonWithType:UIButtonTypeCustom];
    startStopButton.translatesAutoresizingMaskIntoConstraints = NO;
    startStopButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    startStopButton.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    [startStopButton addTarget:self action:@selector(onStartStopTap:) forControlEvents:UIControlEventTouchUpInside];
    [self updateButtonState];

    // Shadow and Radius
    startStopButton.layer.shadowOffset = CGSizeMake(0, 6.0f);
    startStopButton.layer.shadowOpacity = 0.18f;
    startStopButton.layer.shadowRadius = 0.0f;
    startStopButton.layer.masksToBounds = NO;

    [self.view addSubview:startStopButton];

    // Setup autolayout
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:startStopButton
                                                          attribute:NSLayoutAttributeCenterX
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeCenterX
                                                         multiplier:1.0
                                                           constant:0]];

    startButtonScreenHeight = [NSLayoutConstraint constraintWithItem:startStopButton
                                                           attribute:NSLayoutAttributeHeight
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:self.view
                                                           attribute:NSLayoutAttributeHeight
                                                          multiplier:0.33f
                                                            constant:0];

    startButtonScreenWidth = [NSLayoutConstraint constraintWithItem:startStopButton
                                                          attribute:NSLayoutAttributeWidth
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeWidth
                                                         multiplier:0.33f
                                                           constant:0];

    startButtonWidth = [NSLayoutConstraint constraintWithItem:startStopButton
                                                    attribute:NSLayoutAttributeHeight
                                                    relatedBy:NSLayoutRelationEqual
                                                       toItem:startStopButton
                                                    attribute:NSLayoutAttributeWidth
                                                   multiplier:1.0
                                                     constant:0];

    CGSize viewSize = self.view.bounds.size;

    if (viewSize.width > viewSize.height) {
        [self.view addConstraint:startButtonScreenHeight];
    } else {
        [self.view addConstraint:startButtonScreenWidth];
    }

    [self.view addConstraint:startButtonWidth];
}

- (void)addStatusLabel {
    statusLabel = [[UILabel alloc] init];
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel.adjustsFontSizeToFitWidth = YES;
    statusLabel.text = [self getVPNStatusDescription:[vpnManager getVPNStatus]];
    statusLabel.textAlignment = NSTextAlignmentCenter;
    statusLabel.textColor = [UIColor whiteColor];
    [self.view addSubview:statusLabel];

    // Setup autolayout
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:statusLabel
                                                          attribute:NSLayoutAttributeTop
                                                          relatedBy:NSLayoutRelationLessThanOrEqual
                                                             toItem:startStopButton
                                                          attribute:NSLayoutAttributeBottom
                                                         multiplier:1.0
                                                           constant:4.0]];

	[self.view addConstraint:[NSLayoutConstraint constraintWithItem:statusLabel
                                                          attribute:NSLayoutAttributeCenterX
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeCenterX
                                                         multiplier:1.0
                                                           constant:0]];
	// setup layout equal distribution
	UILayoutGuide *leadingGuide = [UILayoutGuide new];
	UILayoutGuide *trailingGuide = [UILayoutGuide new];
	[self.view addLayoutGuide:leadingGuide];
	[self.view addLayoutGuide:trailingGuide];

	[trailingGuide.heightAnchor constraintGreaterThanOrEqualToConstant:.1].active = YES;
	[leadingGuide.heightAnchor constraintEqualToAnchor:trailingGuide.heightAnchor].active = YES;
	[leadingGuide.topAnchor constraintEqualToAnchor:appSubTitleLabel.bottomAnchor].active = YES;
	[leadingGuide.bottomAnchor constraintEqualToAnchor:startStopButton.topAnchor].active = YES;
	[trailingGuide.topAnchor constraintEqualToAnchor:statusLabel.bottomAnchor].active = YES;
	[trailingGuide.bottomAnchor constraintEqualToAnchor:subscriptionButton.topAnchor].active = YES;
}

- (void)addRegionSelectionBar {
    [self addBottomBar];
    [self addRegionButton];
}

- (void)addBottomBar {
    bottomBar = [[UIView alloc] init];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    bottomBar.backgroundColor = [UIColor whiteColor];

    [self.view addSubview:bottomBar];

    // Setup autolayout
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:bottomBar
                                                          attribute:NSLayoutAttributeBottom
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeBottom
                                                         multiplier:1.0
                                                           constant:0]];

    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:bottomBar
                                                          attribute:NSLayoutAttributeLeft
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeLeft
                                                         multiplier:1.0
                                                           constant:0.0]];

    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:bottomBar
                                                          attribute:NSLayoutAttributeRight
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeRight
                                                         multiplier:1.0
                                                           constant:0]];
}

- (void)addRegionButton {
	// Add text above region button first
	regionButtonHeader = [[UILabel alloc] init];
	regionButtonHeader.translatesAutoresizingMaskIntoConstraints = NO;

	regionButtonHeader.text = NSLocalizedStringWithDefaultValue(@"CHANGE_REGION", nil, [NSBundle mainBundle], @"Change Region", @"Text above change region button that allows user to select their desired server region");
	regionButtonHeader.adjustsFontSizeToFitWidth = NO;
	regionButtonHeader.font = [regionButtonHeader.font fontWithSize:14];
	[bottomBar addSubview:regionButtonHeader];

	// Now the button
    regionButton = [[UIButton alloc] init];
    regionButton.translatesAutoresizingMaskIntoConstraints = NO;

    CGFloat buttonHeight = 45;
    regionButton.layer.borderColor = [UIColor lightGrayColor].CGColor;
    regionButton.layer.borderWidth = 1.f;
    regionButton.layer.cornerRadius = buttonHeight / 2;
    [regionButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [regionButton setTitleColor:[UIColor lightGrayColor] forState:UIControlStateHighlighted];
    regionButton.titleLabel.font = [UIFont systemFontOfSize:regionButton.titleLabel.font.pointSize weight:UIFontWeightLight];
    regionButton.titleLabel.adjustsFontSizeToFitWidth = YES;

    CGFloat spacing = 10; // the amount of spacing to appear between image and title
    CGFloat spacingFromSides = 10.f;

    BOOL isRTL = [self isRightToLeft];
    regionButton.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, isRTL ? -spacing : spacing);
    regionButton.titleEdgeInsets = UIEdgeInsetsMake(0, isRTL ? -spacing : spacing, 0, 0);
    regionButton.contentEdgeInsets = UIEdgeInsetsMake(0, spacing + spacingFromSides, 0, spacing + spacingFromSides);
    [regionButton addTarget:self action:@selector(onRegionButtonTap:) forControlEvents:UIControlEventTouchUpInside];
	// Set button height
	[regionButton addConstraint:[NSLayoutConstraint constraintWithItem:regionButton
															 attribute:NSLayoutAttributeHeight
															 relatedBy:NSLayoutRelationEqual
																toItem:nil
															 attribute:NSLayoutAttributeNotAnAttribute
															multiplier:1.0
															  constant:buttonHeight]];
    [bottomBar addSubview:regionButton];
    [self updateRegionButton];
	[self setRegionSelectionConstraints:self.view.frame.size];
}

- (void)addVersionLabel {
    versionLabel = [[UILabel alloc] init];
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionLabel.adjustsFontSizeToFitWidth = YES;
    versionLabel.text = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"APP_VERSION", nil, [NSBundle mainBundle], @"v.%@", @"Text showing the app version. The '%@' placeholder is the version number. So it will look like 'v.2'."),[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]];
    ;
    versionLabel.userInteractionEnabled = YES;
    versionLabel.textColor = [UIColor whiteColor];
	versionLabel.font = [versionLabel.font fontWithSize:13];

#if DEBUG
    UITapGestureRecognizer *tapRecognizer = [[UITapGestureRecognizer alloc]
      initWithTarget:self action:@selector(onVersionLabelTap:)];
    tapRecognizer.numberOfTapsRequired = 1;
    [versionLabel addGestureRecognizer:tapRecognizer];
#endif

    [self.view addSubview:versionLabel];

    // Setup autolayout
    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:versionLabel
                                                          attribute:NSLayoutAttributeLeading
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:self.view
                                                          attribute:NSLayoutAttributeLeading
                                                         multiplier:1.0
                                                           constant:10.0]];

    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:versionLabel
                                                          attribute:NSLayoutAttributeCenterY
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:settingsButton
                                                          attribute:NSLayoutAttributeCenterY
                                                         multiplier:1.0
                                                           constant:0]];

    [self.view addConstraint:[NSLayoutConstraint constraintWithItem:versionLabel
                                                          attribute:NSLayoutAttributeHeight
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:nil
                                                          attribute:NSLayoutAttributeNotAnAttribute
                                                         multiplier:1.0
                                                           constant:50.0]];
}

- (void) addSubscriptionButton {
	subscriptionButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
	subscriptionButton.layer.cornerRadius = 20;
	subscriptionButton.clipsToBounds = YES;
	[subscriptionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	subscriptionButton.backgroundColor = [[UIColor alloc] initWithRed:42.0/255 green:157.0/255 blue:242.0/255 alpha:1];

	subscriptionButton.contentEdgeInsets = UIEdgeInsetsMake(10.0f, 30.0f, 10.0f, 30.0f);

	NSString *subscriptionButtonTitle = NSLocalizedStringWithDefaultValue(@"SUBSCRIPTION_BUTTON_TITLE",
																		  nil,
																		  [NSBundle mainBundle],
																		  @"Go ad-free now!",
																		  @"Text for button that opens paid subscriptions manager UI");
	[subscriptionButton setTitle:subscriptionButtonTitle forState:UIControlStateNormal];
	[subscriptionButton addTarget:self action:@selector(onSubscriptionTap) forControlEvents:UIControlEventTouchUpInside];
	subscriptionButton.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:subscriptionButton];



	// Setup autolayout
	[self.view addConstraint:[NSLayoutConstraint constraintWithItem:subscriptionButton
														  attribute:NSLayoutAttributeCenterX
														  relatedBy:NSLayoutRelationEqual
															 toItem:self.view
														  attribute:NSLayoutAttributeCenterX
														 multiplier:1.0
														   constant:0]];
	[self.view addConstraint:[NSLayoutConstraint constraintWithItem:subscriptionButton
														  attribute:NSLayoutAttributeBottom
														  relatedBy:NSLayoutRelationLessThanOrEqual
															 toItem:bottomBar
														  attribute:NSLayoutAttributeTop
														 multiplier:1.0
														   constant:-10]];
}

#pragma mark - FeedbackViewControllerDelegate methods and helpers

- (NSString *)getPsiphonConfig {
    return [PsiphonClientCommonLibraryHelpers getPsiphonConfigForFeedbackUpload];
}

- (void)userSubmittedFeedback:(NSUInteger)selectedThumbIndex comments:(NSString *)comments email:(NSString *)email uploadDiagnostics:(BOOL)uploadDiagnostics {
    // Ensure psiphon data is populated with latest logs
    // TODO: should this be a delegate method of Psiphon Data in shared library/
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<DiagnosticEntry *> *logs = [sharedDB getNewLogs];
        [[PsiphonData sharedInstance] addDiagnosticEntries:logs];

        __weak MainViewController *weakSelf = self;
        SendFeedbackHandler sendFeedbackHandler = ^(NSString *jsonString, NSString *pubKey, NSString *uploadServer, NSString *uploadServerHeaders){
            PsiphonTunnel *inactiveTunnel = [PsiphonTunnel newPsiphonTunnel:weakSelf]; // TODO: we need to update PsiphonTunnel framework not require this and fix this warning
            [inactiveTunnel sendFeedback:jsonString publicKey:pubKey uploadServer:uploadServer uploadServerHeaders:uploadServerHeaders];
        };

        [FeedbackUpload generateAndSendFeedback:selectedThumbIndex
                                      buildInfo:[PsiphonTunnel getBuildInfo]
                                       comments:comments
                                          email:email
                             sendDiagnosticInfo:uploadDiagnostics
                              withPsiphonConfig:[self getPsiphonConfig]
                             withClientPlatform:@"ios-vpn"
                             withConnectionType:[self getConnectionType]
                                   isJailbroken:[JailbreakCheck isDeviceJailbroken]
                            sendFeedbackHandler:sendFeedbackHandler];
    });
}

- (void)userPressedURL:(NSURL *)URL {
    [[UIApplication sharedApplication] openURL:URL options:@{} completionHandler:nil];
}

// Get connection type for feedback
- (NSString*)getConnectionType {

    Reachability *reachability = [Reachability reachabilityForInternetConnection];

    NetworkStatus status = [reachability currentReachabilityStatus];

    if(status == NotReachable)
    {
        return @"none";
    }
    else if (status == ReachableViaWiFi)
    {
        return @"WIFI";
    }
    else if (status == ReachableViaWWAN)
    {
        return @"mobile";
    }

    return @"error";
}

#pragma mark - PsiphonSettingsViewControllerDelegate methods and helpers

- (void)notifyPsiphonConnectionState {
    // Unused
}

- (void)reloadAndOpenSettings {
    if (appSettingsViewController != nil) {
        __weak MainViewController *weakSelf = self;
        [appSettingsViewController dismissViewControllerAnimated:NO completion:^{
            [[RegionAdapter sharedInstance] reloadTitlesForNewLocalization];
            [[AppDelegate sharedAppDelegate] reloadMainViewController];
        }];
    }
}

- (void)settingsWillDismissWithForceReconnect:(BOOL)forceReconnect {
    if (forceReconnect) {
        [self persistSettingsToSharedUserDefaults];
        [vpnManager restartVPN];
    }
}

- (void)persistSettingsToSharedUserDefaults {
    [self persistDisableTimeouts];
    [self persistSelectedRegion];
    [self persistUpstreamProxySettings];
}

- (void)persistDisableTimeouts {
    NSUserDefaults *containerUserDefaults = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *sharedUserDefaults = [[NSUserDefaults alloc] initWithSuiteName:APP_GROUP_IDENTIFIER];
    [sharedUserDefaults setObject:@([containerUserDefaults boolForKey:kDisableTimeouts]) forKey:kDisableTimeouts];
}

- (void)persistSelectedRegion {
    [[PsiphonConfigUserDefaults sharedInstance] setEgressRegion:[RegionAdapter.sharedInstance getSelectedRegion].code];
}

- (void)persistUpstreamProxySettings {
    NSString *upstreamProxyUrl = [[UpstreamProxySettings sharedInstance] getUpstreamProxyUrl];
    NSUserDefaults *userDefaults = [[NSUserDefaults alloc] initWithSuiteName:APP_GROUP_IDENTIFIER];
    [userDefaults setObject:upstreamProxyUrl forKey:PSIPHON_CONFIG_UPSTREAM_PROXY_URL];
}

- (BOOL)shouldEnableSettingsLinks {
    return YES;
}

- (NSArray<NSString*>*)hiddenSpecifierKeys {
    VPNStatus status = [vpnManager getVPNStatus];
    if (status == VPNStatusInvalid ||
        status == VPNStatusDisconnected ||
        status == VPNStatusDisconnecting) {
        return @[kForceReconnect, kForceReconnectFooter];
    }
    return nil;
}

#pragma mark - Psiphon Settings

- (void)openSettingsMenu {
    appSettingsViewController = [[SettingsViewController alloc] init];
    appSettingsViewController.delegate = appSettingsViewController;
    appSettingsViewController.showCreditsFooter = NO;
    appSettingsViewController.showDoneButton = YES;
    appSettingsViewController.neverShowPrivacySettings = YES;
    appSettingsViewController.settingsDelegate = self;
    appSettingsViewController.preferencesSnapshot = [[[NSUserDefaults standardUserDefaults] dictionaryRepresentation] copy];

    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:appSettingsViewController];
    [self presentViewController:navController animated:YES completion:nil];
}

#pragma mark - Region Selection

- (void)openRegionSelection {
    selectedRegionSnapShot = [[RegionAdapter sharedInstance] getSelectedRegion].code;
    RegionSelectionViewController *regionSelectionViewController = [[RegionSelectionViewController alloc] init];
    regionSelectionNavController = [[UINavigationController alloc] initWithRootViewController:regionSelectionViewController];
    UIBarButtonItem *doneButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedStringWithDefaultValue(@"DONE_ACTION", nil, [NSBundle mainBundle], @"Done", @"Title of the button that dismisses region selection dialog")
                                                                   style:UIBarButtonItemStyleDone target:self
                                                                  action:@selector(regionSelectionDidEnd)];
    regionSelectionViewController.navigationItem.rightBarButtonItem = doneButton;

    [self presentViewController:regionSelectionNavController animated:YES completion:nil];
}

- (void)regionSelectionDidEnd {
    NSString *selectedRegion = [[RegionAdapter sharedInstance] getSelectedRegion].code;//[[[NSUserDefaults alloc] initWithSuiteName:APP_GROUP_IDENTIFIER] stringForKey:kRegionSelectionSpecifierKey];
    if (!safeStringsEqual(selectedRegion, selectedRegionSnapShot)) {
        [self persistSelectedRegion];
        [self updateRegionButton];
        [vpnManager restartVPN];
    }
    [regionSelectionNavController dismissViewControllerAnimated:YES completion:nil];
    regionSelectionNavController = nil;
}

- (void)updateAvailableRegions {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSString *> *regions = [sharedDB getAllEgressRegions];
        [[RegionAdapter sharedInstance] onAvailableEgressRegions:regions];
    });
}

- (void)updateRegionButton {
    Region *selectedRegion = [[RegionAdapter sharedInstance] getSelectedRegion];
    UIImage *flag = [[PsiphonClientCommonLibraryHelpers imageFromCommonLibraryNamed:selectedRegion.flagResourceId] countryFlag];
    [regionButton setImage:flag forState:UIControlStateNormal];

    NSString *regionText = [[RegionAdapter sharedInstance] getLocalizedRegionTitle:selectedRegion.code];
    [regionButton setTitle:regionText forState:UIControlStateNormal];
}

- (void) setRegionSelectionConstraints:(CGSize) size {
    [bottomBar removeConstraints:[bottomBar constraints]];
    if (size.width > size.height) {
        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButton
                                                              attribute:NSLayoutAttributeBottom
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:bottomBar
                                                              attribute:NSLayoutAttributeBottom
                                                             multiplier:1.0
                                                               constant:-7]];

        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButton
                                                              attribute:NSLayoutAttributeTop
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:bottomBar
                                                              attribute:NSLayoutAttributeTop
                                                             multiplier:1.0
                                                               constant:7]];

// Option 2
        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButton
                                                              attribute:NSLayoutAttributeCenterX
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:bottomBar
                                                              attribute:NSLayoutAttributeCenterX
                                                             multiplier:1.0
                                                               constant:0]];
//

        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButtonHeader
                                                              attribute:NSLayoutAttributeCenterY
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:regionButton
                                                              attribute:NSLayoutAttributeCenterY
                                                             multiplier:1.0
                                                               constant:0]];

        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButtonHeader
                                                              attribute:NSLayoutAttributeTrailing
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:regionButton
                                                              attribute:NSLayoutAttributeLeading
                                                             multiplier:1.0
                                                               constant:-5]];
// Option 3
        regionButtonHeader.hidden = YES;
//

/*
 // Option 1
        // Add left and right padding with layout guides
        for (UILayoutGuide * guide in [bottomBar layoutGuides]) {
            [bottomBar removeLayoutGuide:guide];
        }
        UILayoutGuide *leadingGuide = [UILayoutGuide new];
        UILayoutGuide *trailingGuide = [UILayoutGuide new];
        [bottomBar addLayoutGuide:leadingGuide];
        [bottomBar addLayoutGuide:trailingGuide];

        [trailingGuide.widthAnchor constraintGreaterThanOrEqualToConstant:.1].active = YES;
        [leadingGuide.widthAnchor constraintEqualToAnchor:trailingGuide.widthAnchor].active = YES;
        [leadingGuide.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor].active = YES;
        [leadingGuide.trailingAnchor constraintEqualToAnchor:regionButtonHeader.leadingAnchor].active = YES;
        [trailingGuide.leadingAnchor constraintEqualToAnchor:regionButton.trailingAnchor].active = YES;
        [trailingGuide.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor].active = YES;
 */
    } else {
        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButtonHeader
                                                              attribute:NSLayoutAttributeTop
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:bottomBar
                                                              attribute:NSLayoutAttributeTop
                                                             multiplier:1.0
                                                               constant:5]];

        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButtonHeader
                                                              attribute:NSLayoutAttributeCenterX
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:bottomBar
                                                              attribute:NSLayoutAttributeCenterX
                                                             multiplier:1.0
                                                               constant:0]];


        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButton
                                                              attribute:NSLayoutAttributeBottom
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:bottomBar
                                                              attribute:NSLayoutAttributeBottom
                                                             multiplier:1.0
                                                               constant:-7]];

        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButton
                                                              attribute:NSLayoutAttributeTop
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:regionButtonHeader
                                                              attribute:NSLayoutAttributeBottom
                                                             multiplier:1.0
                                                               constant:7]];

        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButton
                                                              attribute:NSLayoutAttributeCenterX
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:bottomBar
                                                              attribute:NSLayoutAttributeCenterX
                                                             multiplier:1.0
                                                               constant:0]];

        NSLayoutConstraint *widthConstraint = [NSLayoutConstraint constraintWithItem:regionButton
                                                                           attribute:NSLayoutAttributeWidth
                                                                           relatedBy:NSLayoutRelationEqual
                                                                              toItem:bottomBar
                                                                           attribute:NSLayoutAttributeWidth
                                                                          multiplier:.7
                                                                            constant:0];
        widthConstraint.priority = 999; // allow constraint to be broken to enforce max width
        [bottomBar addConstraint:widthConstraint];

        [bottomBar addConstraint:[NSLayoutConstraint constraintWithItem:regionButton
                                                              attribute:NSLayoutAttributeWidth
                                                              relatedBy:NSLayoutRelationLessThanOrEqual
                                                                 toItem:nil
                                                              attribute:NSLayoutAttributeNotAnAttribute
                                                             multiplier:1.0
                                                               constant:220]];
    }
}

#pragma mark - IAP

- (void) openIAPViewController {
	IAPViewController *iapViewController = [[IAPViewController alloc]init];
	iapViewController.openedFromSettings = NO;
	UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:iapViewController];
	[self presentViewController:navController animated:YES completion:nil];
}

- (void)updatedIAPTransactionState {
	if (![adManager shouldShowUntunneledAds]) {
		// if user subscription state has changed to valid
		// try to deinit ads if currently not showing and hide adLabel
		[adManager initializeAds];
	}
}
@end
