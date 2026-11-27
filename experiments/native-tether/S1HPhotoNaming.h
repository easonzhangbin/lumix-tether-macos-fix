#import <Foundation/Foundation.h>

static inline BOOL s1h_photo_prefix_valid(NSString *prefix) {
    if (![prefix isKindOfClass:NSString.class]) return NO;
    if (!prefix.length) return YES;
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if (![prefix isEqualToString:[prefix stringByTrimmingCharactersInSet:whitespace]] ||
        [prefix hasPrefix:@"."] || [prefix hasSuffix:@"."] ||
        [prefix rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        [prefix rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
        [prefix rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"<>:\"/\\|?*"]].location != NSNotFound)
        return NO;
    NSUInteger bytes = [prefix.decomposedStringWithCanonicalMapping lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return bytes > 0 && bytes <= 120;
}
