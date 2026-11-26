#import <Preferences/PSListController.h>

@interface DWRootListController : PSListController
@end

@implementation DWRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
