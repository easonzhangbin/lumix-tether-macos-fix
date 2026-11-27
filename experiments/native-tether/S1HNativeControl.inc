/* Independent Panasonic scalar-control protocol implementation.
 * Included after NativePreviewTransport's interface declaration.
 * Protocol references: CONTROL-PROTOCOL.md; no upstream implementation copied.
 */
static NSArray<NSDictionary *> *s1h_control_specs(void) {
    return @[
        @{@"key":@"iso", @"label":@"ISO", @"group":@0x02000020, @"list":@0x02000020, @"read":@0x02000021, @"write":@0x02000021, @"width":@4},
        @{@"key":@"shutter", @"label":@"Shutter", @"group":@0x02000030, @"list":@0x02000030, @"read":@0, @"write":@0x02000031, @"width":@4},
        @{@"key":@"aperture", @"label":@"Aperture", @"group":@0x02000040, @"list":@0x02000040, @"read":@0x02000041, @"write":@0x02000041, @"width":@2},
        @{@"key":@"white_balance", @"label":@"White balance", @"group":@0x02000050, @"list":@0x02000051, @"read":@0, @"write":@0x02000051, @"width":@2},
        @{@"key":@"color_temperature", @"label":@"Color temperature", @"group":@0x02000050, @"list":@0x02000052, @"read":@0, @"write":@0x02000052, @"width":@2},
        @{@"key":@"exposure_compensation", @"label":@"Exposure compensation", @"group":@0x02000060, @"list":@0x02000060, @"read":@0, @"write":@0x02000061, @"width":@2},
        @{@"key":@"focus_mode", @"label":@"Focus mode", @"group":@0x02000070, @"list":@0x02000071, @"read":@0, @"write":@0x02000071, @"width":@2}
    ];
}
static NSDictionary *s1h_control_spec(NSString *key) {
    for (NSDictionary *spec in s1h_control_specs()) if ([spec[@"key"] isEqual:key]) return spec;
    return nil;
}
static BOOL s1h_control_identity(NSDictionary *spec, uint32_t code) {
    return code == [spec[@"group"] unsignedIntValue] || code == [spec[@"list"] unsignedIntValue] ||
           code == [spec[@"write"] unsignedIntValue];
}
static const uint32_t S1HShutterFallbackProperty = 0x02000030;
static const uint32_t S1HDriveModeGroup = 0x02000080;
static const uint32_t S1HDriveModeProperty = 0x02000081;
static const uint16_t S1HHighResolutionDriveMode = 9;

static BOOL s1h_control_read_allowed(uint16_t opcode, NSArray<NSNumber *> *parameters) {
    if (opcode == 0x9108 && parameters.count == 2 && parameters[0].unsignedIntValue == S1HDriveModeGroup &&
        parameters[1].unsignedIntValue == S1HDriveModeProperty) return YES;
    if (opcode == 0x9108 && parameters.count == 3 && parameters[1].unsignedIntValue == 0 && parameters[2].unsignedIntValue == 0) {
        for (NSDictionary *spec in s1h_control_specs()) if (parameters[0].unsignedIntValue == [spec[@"list"] unsignedIntValue]) return YES;
    }
    if (opcode == 0x9402 && parameters.count == 1) {
        uint32_t property = parameters[0].unsignedIntValue;
        if (property == S1HShutterFallbackProperty || property == S1HDriveModeProperty) return YES;
        for (NSDictionary *spec in s1h_control_specs())
            if (property != 0 && property == [spec[@"read"] unsignedIntValue]) return YES;
    }
    return NO;
}
static BOOL s1h_control_data_allowed(uint16_t opcode, NSArray<NSNumber *> *parameters, NSData *payload) {
    if (opcode != 0x9403 || parameters.count != 1 || payload.length < 8) return NO;
    const unsigned char *bytes = payload.bytes;
    uint32_t property = parameters[0].unsignedIntValue;
    for (NSDictionary *spec in s1h_control_specs()) {
        NSUInteger width = [spec[@"width"] unsignedIntegerValue];
        if (property == [spec[@"write"] unsignedIntValue])
            return payload.length == 8 + width && read32(bytes) == property && read16(bytes + 4) == width && bytes[6] == 0 && bytes[7] == 0;
    }
    return NO;
}
static BOOL s1h_control_raw_valid(NSNumber *value, NSUInteger width) {
    if (![value isKindOfClass:NSNumber.class] || (width != 2 && width != 4)) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double raw = value.doubleValue;
    return isfinite(raw) && floor(raw) == raw && raw >= 0 && raw <= (width == 2 ? UINT16_MAX : UINT32_MAX);
}
static NSData *s1h_control_pack(NSDictionary *spec, NSNumber *value) {
    NSUInteger width = [spec[@"width"] unsignedIntegerValue];
    if (!spec || !s1h_control_raw_valid(value, width)) return nil;
    NSMutableData *payload = [NSMutableData dataWithLength:8 + width];
    unsigned char *bytes = payload.mutableBytes;
    write32(bytes, [spec[@"write"] unsignedIntValue]); write16(bytes + 4, (uint16_t)width);
    if (width == 2) write16(bytes + 8, value.unsignedShortValue); else write32(bytes + 8, value.unsignedIntValue);
    return payload;
}
static NSDictionary *s1h_control_parse_descriptor(NSData *data, NSDictionary *spec, NSString **error) {
#define CONTROL_BAD(message) do { if (error) *error = (message); return nil; } while (0)
    if (data.length < 32) CONTROL_BAD(@"Camera descriptor header is incomplete.");
    const unsigned char *bytes = data.bytes;
    NSUInteger width = [spec[@"width"] unsignedIntegerValue];
    if ((width != 2 && width != 4) || !s1h_control_identity(spec, read32(bytes + 28)))
        CONTROL_BAD(@"Camera descriptor property or scalar width is unsupported.");
    uint64_t offset64 = (uint64_t)read32(bytes + 4) * 4 + 8;
    if (offset64 < 32 || offset64 > data.length || width + 4 > data.length - (NSUInteger)offset64)
        CONTROL_BAD(@"Camera descriptor current value is outside the data.");
    NSUInteger offset = (NSUInteger)offset64;
    uint32_t current = width == 2 ? read16(bytes + offset) : read32(bytes + offset);
    offset += width;
    uint32_t count = read32(bytes + offset); offset += 4;
    if (count > 1024 || count > (data.length - offset) / width)
        CONTROL_BAD(@"Camera descriptor choices exceed their bounded data.");
    NSMutableArray *options = [NSMutableArray arrayWithCapacity:count];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSUInteger i = 0; i < count; ++i) {
        NSNumber *raw = @(width == 2 ? read16(bytes + offset + i * width) : read32(bytes + offset + i * width));
        if (![seen containsObject:raw]) { [seen addObject:raw]; [options addObject:raw]; }
    }
    return @{@"current":@(current), @"raw_options":options};
#undef CONTROL_BAD
}
static NSNumber *s1h_control_parse_scalar(NSData *data, NSDictionary *spec, NSString **error) {
    NSUInteger width = [spec[@"width"] unsignedIntegerValue];
    if (data.length < 8 + width) { if (error) *error = @"Camera scalar value is truncated."; return nil; }
    const unsigned char *bytes = data.bytes;
    if (!s1h_control_identity(spec, read32(bytes)) || read32(bytes + 4) != width) {
        if (error) *error = @"Camera scalar property or width differs from its control.";
        return nil;
    }
    return @(width == 2 ? read16(bytes + 8) : read32(bytes + 8));
}
static NSString *s1h_control_value_label(NSString *key, NSNumber *value) {
    uint32_t raw = value.unsignedIntValue;
    if ([key isEqual:@"iso"] && raw == UINT32_MAX) return @"AUTO";
    if ([key isEqual:@"aperture"]) return [NSString stringWithFormat:@"f/%.1f", raw / 10.0];
    if ([key isEqual:@"shutter"]) {
        if (raw == UINT32_MAX) return @"Bulb";
        if (raw & 0x80000000) return [NSString stringWithFormat:@"%g s", (raw & 0x7fffffff) / 1000.0];
        return raw ? [NSString stringWithFormat:@"1/%g s", raw / 1000.0] : @"0 (camera value)";
    }
    if ([key isEqual:@"color_temperature"]) return [NSString stringWithFormat:@"%u K", raw];
    if ([key isEqual:@"exposure_compensation"]) {
        double steps = raw & 0x8000 ? -(double)(raw & 0x7fff) : raw;
        return [NSString stringWithFormat:@"%+.2f EV", steps / 3.0];
    }
    if ([key isEqual:@"white_balance"]) {
        NSDictionary *names = @{@2:@"Auto", @4:@"Daylight", @5:@"Fluorescent", @6:@"Tungsten", @7:@"Flash",
            @0x8008:@"Cloudy", @0x8009:@"White Set", @0x800b:@"White Set 1", @0x800c:@"White Set 2",
            @0x800d:@"White Set 3", @0x800e:@"White Set 4", @0x800f:@"Shade", @0x8010:@"Temperature 1",
            @0x8011:@"Temperature 2", @0x8012:@"Temperature 3", @0x8013:@"Temperature 4", @0x8014:@"Auto cool", @0x8015:@"Auto warm"};
        return names[value] ?: [NSString stringWithFormat:@"0x%04X", raw];
    }
    if ([key isEqual:@"focus_mode"]) {
        NSArray *names = @[@"AF", @"Macro", @"Macro (D)", @"MF", @"AF-S", @"AF-C", @"AF-F"];
        return raw < names.count ? names[raw] : [NSString stringWithFormat:@"0x%04X", raw];
    }
    return [NSString stringWithFormat:@"%u", raw];
}
static NSDictionary *s1h_control_unavailable(NSDictionary *spec, NSString *reason) {
    return @{@"label":spec[@"label"] ?: @"Camera control", @"current":NSNull.null, @"options":@[], @"writable":@NO,
             @"available":@NO, @"reason":reason ?: @"Camera control is unavailable."};
}
static NSDictionary *s1h_control_query(NativePreviewTransport *transport, NSDictionary *spec) {
    if (StopRequested || !transport.synchronized) return s1h_control_unavailable(spec, @"Control inspection was interrupted.");
    uint32_t list = [spec[@"list"] unsignedIntValue];
    PreviewReply *reply = [transport request:0x9108 parameters:@[@(list), @0, @0] dataExpected:YES];
    if (!reply || reply.code != 0x2001)
        return s1h_control_unavailable(spec, reply ? [NSString stringWithFormat:@"Camera descriptor response 0x%04X.", reply.code] : transport.error);
    NSString *error = nil;
    NSDictionary *descriptor = s1h_control_parse_descriptor(reply.data, spec, &error);
    if (!descriptor) return s1h_control_unavailable(spec, error);
    NSNumber *current = descriptor[@"current"];
    uint32_t readProperty = [spec[@"read"] unsignedIntValue];
    if ([spec[@"key"] isEqual:@"shutter"] && current.unsignedIntValue == 0) readProperty = S1HShutterFallbackProperty;
    if (readProperty) {
        if (StopRequested) return s1h_control_unavailable(spec, @"Control inspection was cancelled.");
        reply = [transport request:0x9402 parameters:@[@(readProperty)] dataExpected:YES];
        if (!reply || reply.code != 0x2001)
            return s1h_control_unavailable(spec, reply ? [NSString stringWithFormat:@"Camera current-value response 0x%04X.", reply.code] : transport.error);
        current = s1h_control_parse_scalar(reply.data, spec, &error);
        if (!current) return s1h_control_unavailable(spec, error);
    }
    NSMutableArray *options = [NSMutableArray array];
    for (NSNumber *raw in descriptor[@"raw_options"])
        [options addObject:@{@"value":raw, @"label":s1h_control_value_label(spec[@"key"], raw)}];
    return @{@"label":spec[@"label"], @"current":current,
             @"current_label":s1h_control_value_label(spec[@"key"], current), @"options":options,
             @"writable":@((BOOL)(options.count > 0)), @"available":@YES,
             @"reason":options.count ? @"Camera-reported options; acceptance can depend on the current mode." : @"Camera reported no selectable values."};
}

/* The compact descriptor starts with a 28-byte group header and one 28-byte
 * subtag header. Only parameter 1's explicitly typed enumeration describes
 * selectable drive modes. A descriptor default is not the current mode. */
static NSNumber *s1h_drive_mode_high_resolution_reported(NSData *data) {
    const NSUInteger headerLength = 28;
    if (data.length < 2 * headerLength) return nil;
    const unsigned char *group = data.bytes;
    const unsigned char *subtag = group + headerLength;
    if (read32(group + 20) != 1 || read32(subtag) != S1HDriveModeProperty) return nil;
    NSUInteger bodyLength = read32(subtag + 24);
    NSUInteger parameterCount = read16(subtag + 20);
    if (bodyLength > data.length - 2 * headerLength || parameterCount > bodyLength / 8) return nil;
    const unsigned char *parameter = subtag + headerLength;
    for (NSUInteger i = 0; i < parameterCount; ++i) {
        if (bodyLength < 8) return nil;
        NSUInteger length = read32(parameter + 4);
        if (length > bodyLength - 8) return nil;
        if (read32(parameter) == 1) {
            const NSUInteger tagAndLength = 8;
            const NSUInteger enumValuesOffset = 38;
            if (length < enumValuesOffset - tagAndLength || read16(parameter + 24) != 4 ||
                read32(parameter + 28) != 2) return nil;
            uint32_t count = read32(parameter + 34);
            if (count > 1024 || count > (length + tagAndLength - enumValuesOffset) / 2) return nil;
            for (uint32_t index = 0; index < count; ++index)
                if (read16(parameter + enumValuesOffset + 2 * index) == S1HHighResolutionDriveMode) return @YES;
            return @NO;
        }
        parameter += 8 + length;
        bodyLength -= 8 + length;
    }
    return nil;
}

static NSDictionary *s1h_drive_mode_query(NativePreviewTransport *transport) {
    NSDictionary *spec = @{@"label":@"Drive mode"};
    if (StopRequested || !transport.synchronized)
        return s1h_control_unavailable(spec, @"Control inspection was interrupted.");

    PreviewReply *reply = [transport request:0x9402 parameters:@[@(S1HDriveModeProperty)] dataExpected:YES];
    const unsigned char *bytes = reply.data.bytes;
    if (reply.code != 0x2001 || reply.data.length != 10 || read32(bytes) != S1HDriveModeProperty ||
        read32(bytes + 4) != 2) return s1h_control_unavailable(spec, @"Camera did not report its current drive mode.");

    uint16_t mode = read16(bytes + 8);
    NSString *label = @{@0:@"Single", @(S1HHighResolutionDriveMode):@"High Resolution",
                        @10:@"Handheld High Resolution"}[@(mode)] ?: [NSString stringWithFormat:@"0x%04X", mode];
    NSMutableDictionary *control = [@{@"label":spec[@"label"], @"current":@(mode), @"current_label":label,
        @"available":@YES, @"writable":@NO, @"options":@[], @"reason":@"Change drive mode on the camera."} mutableCopy];
    if (!StopRequested && transport.synchronized) {
        PreviewReply *descriptor = [transport request:0x9108 parameters:@[@(S1HDriveModeGroup), @(S1HDriveModeProperty)] dataExpected:YES];
        if (descriptor.code == 0x2001) {
            NSNumber *reported = s1h_drive_mode_high_resolution_reported(descriptor.data);
            if (reported) control[@"high_resolution_switch_reported"] = reported;
        }
    }
    return control;
}

static NSDictionary *s1h_controls_refresh(NativePreviewTransport *transport) {
    NSMutableDictionary *controls = [NSMutableDictionary dictionary];
    for (NSDictionary *spec in s1h_control_specs()) controls[spec[@"key"]] = s1h_control_query(transport, spec);
    controls[@"drive_mode"] = s1h_drive_mode_query(transport);
    return controls;
}
static NSDictionary *s1h_control_set(NativePreviewTransport *transport, NSString *key, NSNumber *raw, NSDictionary **updatedControls) {
    NSDictionary *spec = s1h_control_spec(key);
    if (!spec || !s1h_control_raw_valid(raw, [spec[@"width"] unsignedIntegerValue]))
        return @{@"status":@"rejected", @"message":@"Unknown control or invalid raw value."};
    NSDictionary *fresh = s1h_control_query(transport, spec);
    if (updatedControls) *updatedControls = @{key:fresh};
    BOOL listed = NO;
    for (NSDictionary *option in fresh[@"options"]) if ([option[@"value"] isEqual:raw]) { listed = YES; break; }
    if (![fresh[@"available"] boolValue] || ![fresh[@"writable"] boolValue] || !listed || StopRequested)
        return @{@"status":@"rejected", @"message":@"Value is not a currently reported camera option."};
    if ([fresh[@"current"] isEqual:raw])
        return @{@"status":@"ok", @"message":[NSString stringWithFormat:@"%@ already matches the requested value.", spec[@"label"]]};

    NSData *payload = s1h_control_pack(spec, raw);
    PreviewReply *reply = [transport request:0x9403 parameters:@[spec[@"write"]] dataExpected:NO dataOut:payload];
    if (!reply) {
        if (updatedControls) *updatedControls = @{key:s1h_control_unavailable(spec, @"Setting outcome is unknown; refresh after reconnecting.")};
        return @{@"status":@"outcome_unknown", @"message":transport.error ?: @"Setting transaction did not complete; it was not retried."};
    }
    if (!transport.synchronized || StopRequested) {
        if (updatedControls) *updatedControls = @{key:s1h_control_unavailable(spec, @"Setting read-back was interrupted.")};
        return @{@"status":@"outcome_unknown", @"message":@"Setting was submitted but verification was interrupted."};
    }
    NSDictionary *observed = s1h_control_query(transport, spec);
    if (updatedControls) {
        NSString *linkedKey = nil;
        if ([key isEqual:@"white_balance"]) linkedKey = @"color_temperature";
        if ([key isEqual:@"color_temperature"]) linkedKey = @"white_balance";
        *updatedControls = linkedKey ? @{key:observed, linkedKey:s1h_control_query(transport, s1h_control_spec(linkedKey))} : @{key:observed};
    }
    if (reply.code != 0x2001)
        return @{@"status":@"error", @"message":[NSString stringWithFormat:@"Camera declined setting with response 0x%04X; no write retry was made.", reply.code]};
    if (![observed[@"available"] boolValue] || ![observed[@"current"] isEqual:raw])
        return @{@"status":transport.synchronized ? @"error" : @"outcome_unknown", @"message":@"Camera setting was not confirmed by read-back."};
    return @{@"status":@"ok", @"message":[NSString stringWithFormat:@"%@ updated and verified.", spec[@"label"]]};
}

/* Scripted replies exercise the production queries and setter without opening USB. */
@interface S1HControlFixtureTransport : NativePreviewTransport
@property(nonatomic, copy) NSArray *fixtureReplies;
@property(nonatomic, strong) NSMutableArray *fixtureRequests;
@end

@implementation S1HControlFixtureTransport
- (PreviewReply *)request:(uint16_t)opcode parameters:(NSArray<NSNumber *> *)parameters
             dataExpected:(BOOL)expected dataOut:(NSData *)dataOut {
    NSUInteger index = self.fixtureRequests.count;
    [self.fixtureRequests addObject:@[@(opcode), parameters, @(expected), dataOut ?: NSNull.null]];
    id reply = index < self.fixtureReplies.count ? self.fixtureReplies[index] : nil;
    if (![reply isKindOfClass:PreviewReply.class]) {
        self.synchronized = NO;
        self.error = @"Fixture transaction ended without a response.";
        return nil;
    }
    PreviewReply *complete = reply;
    if (complete.code == 0x2001 && expected && !complete.data) {
        self.error = @"Fixture returned OK without the required data phase.";
        return nil;
    }
    return complete;
}
@end

static PreviewReply *s1h_control_fixture_reply(uint16_t code, NSData *data) {
    PreviewReply *reply = [PreviewReply new];
    reply.code = code;
    reply.data = data;
    return reply;
}

static PreviewReply *s1h_control_fixture_descriptor(uint32_t property, uint16_t current,
                                                     uint16_t first, uint16_t second) {
    NSMutableData *data = [NSMutableData dataWithLength:42];
    unsigned char *bytes = data.mutableBytes;
    write32(bytes + 4, 6);
    write32(bytes + 28, property);
    write16(bytes + 32, current);
    write32(bytes + 34, 2);
    write16(bytes + 38, first);
    write16(bytes + 40, second);
    return s1h_control_fixture_reply(0x2001, data);
}

static BOOL s1h_control_setter_self_test(void) {
    S1HControlFixtureTransport *transport = [S1HControlFixtureTransport new];
    transport.fixtureRequests = [NSMutableArray array];
    transport.synchronized = YES;
    PreviewReply *initial = s1h_control_fixture_descriptor(0x02000051, 2, 2, 0x8010);
    PreviewReply *updated = s1h_control_fixture_descriptor(0x02000051, 0x8010, 2, 0x8010);
    PreviewReply *kelvin = s1h_control_fixture_descriptor(0x02000052, 5600, 5500, 5600);
    transport.fixtureReplies = @[initial];
    NSDictionary *controls = nil;
    NSDictionary *result = s1h_control_set(transport, @"white_balance", @4, &controls);
    BOOL ok = [result[@"status"] isEqual:@"rejected"] && transport.fixtureRequests.count == 1 &&
        [controls[@"white_balance"][@"current"] isEqual:@2];

    [transport.fixtureRequests removeAllObjects];
    result = s1h_control_set(transport, @"white_balance", @2, &controls);
    ok = ok && [result[@"status"] isEqual:@"ok"] && transport.fixtureRequests.count == 1;

    [transport.fixtureRequests removeAllObjects];
    PreviewReply *writeOK = s1h_control_fixture_reply(0x2001, nil);
    transport.fixtureReplies = @[initial, writeOK, updated, kelvin];
    result = s1h_control_set(transport, @"white_balance", @0x8010, &controls);
    NSData *expectedSet = s1h_control_pack(s1h_control_spec(@"white_balance"), @0x8010);
    NSArray *readWB = @[@0x9108, @[@0x02000051, @0, @0], @YES, NSNull.null];
    NSArray *writeWB = @[@0x9403, @[@0x02000051], @NO, expectedSet];
    NSArray *readKelvin = @[@0x9108, @[@0x02000052, @0, @0], @YES, NSNull.null];
    ok = ok && [result[@"status"] isEqual:@"ok"] &&
        [transport.fixtureRequests isEqual:@[readWB, writeWB, readWB, readKelvin]] &&
        [controls[@"white_balance"][@"current"] isEqual:@0x8010] &&
        [controls[@"color_temperature"][@"current_label"] isEqual:@"5600 K"];

    [transport.fixtureRequests removeAllObjects];
    transport.fixtureReplies = @[initial, writeOK, initial, kelvin];
    result = s1h_control_set(transport, @"white_balance", @0x8010, &controls);
    ok = ok && [result[@"status"] isEqual:@"error"] && transport.fixtureRequests.count == 4 &&
        [controls[@"white_balance"][@"current"] isEqual:@2];

    [transport.fixtureRequests removeAllObjects];
    transport.fixtureReplies = @[initial, NSNull.null];
    result = s1h_control_set(transport, @"white_balance", @0x8010, &controls);
    return ok && [result[@"status"] isEqual:@"outcome_unknown"] && transport.fixtureRequests.count == 2 &&
        ![controls[@"white_balance"][@"available"] boolValue];
}

static BOOL s1h_drive_mode_self_test(void) {
    S1HControlFixtureTransport *transport = [S1HControlFixtureTransport new];
    transport.fixtureRequests = [NSMutableArray array];
    transport.synchronized = YES;
    NSMutableData *scalar = [NSMutableData dataWithLength:10];
    unsigned char *bytes = scalar.mutableBytes;
    write32(bytes, S1HDriveModeProperty);
    write32(bytes + 4, 2);
    write16(bytes + 8, S1HHighResolutionDriveMode);

    NSMutableData *descriptor = [NSMutableData dataWithLength:98];
    unsigned char *group = descriptor.mutableBytes;
    write32(group + 20, 1);
    unsigned char *subtag = group + 28;
    write32(subtag, S1HDriveModeProperty);
    write16(subtag + 20, 1);
    write32(subtag + 24, 42);
    unsigned char *parameter = subtag + 28;
    write32(parameter, 1);
    write32(parameter + 4, 34);
    write16(parameter + 24, 4);
    write32(parameter + 28, 2);
    write32(parameter + 34, 2);
    write16(parameter + 38, 0);
    write16(parameter + 40, S1HHighResolutionDriveMode);

    PreviewReply *current = s1h_control_fixture_reply(0x2001, scalar);
    transport.fixtureReplies = @[current, s1h_control_fixture_reply(0x2001, descriptor)];
    NSDictionary *mode = s1h_drive_mode_query(transport);
    NSArray *readMode = @[@0x9402, @[@(S1HDriveModeProperty)], @YES, NSNull.null];
    NSArray *readDescriptor = @[@0x9108, @[@(S1HDriveModeGroup), @(S1HDriveModeProperty)], @YES, NSNull.null];
    BOOL ok = [mode[@"current"] isEqual:@(S1HHighResolutionDriveMode)] &&
        [mode[@"current_label"] isEqual:@"High Resolution"] && [mode[@"available"] boolValue] &&
        ![mode[@"writable"] boolValue] && [mode[@"options"] count] == 0 &&
        [mode[@"high_resolution_switch_reported"] isEqual:@YES] &&
        [transport.fixtureRequests isEqual:@[readMode, readDescriptor]] &&
        s1h_control_read_allowed(0x9402, readMode[1]) && s1h_control_read_allowed(0x9108, readDescriptor[1]) &&
        !s1h_control_data_allowed(0x9403, @[@0], scalar) &&
        !s1h_control_data_allowed(0x9403, @[@(S1HDriveModeProperty)], scalar);

    write32(parameter + 34, UINT32_MAX);
    ok = ok && !s1h_drive_mode_high_resolution_reported(descriptor);
    write32(parameter + 34, 0);
    ok = ok && [s1h_drive_mode_high_resolution_reported(descriptor) isEqual:@NO];

    [transport.fixtureRequests removeAllObjects];
    write16(bytes + 8, 10);
    transport.fixtureReplies = @[current, s1h_control_fixture_reply(0x2001, nil)];
    mode = s1h_drive_mode_query(transport);
    ok = ok && transport.synchronized && [mode[@"current_label"] isEqual:@"Handheld High Resolution"] &&
        !mode[@"high_resolution_switch_reported"];

    [transport.fixtureRequests removeAllObjects];
    transport.fixtureReplies = @[s1h_control_fixture_reply(0x2005, nil)];
    mode = s1h_drive_mode_query(transport);
    return ok && transport.synchronized && ![mode[@"available"] boolValue] &&
        [transport.fixtureRequests isEqual:@[readMode]];
}

static BOOL s1h_controls_self_test(void) {
    NSDictionary *spec = s1h_control_spec(@"aperture");
    NSData *packed = s1h_control_pack(spec, @28);
    BOOL ok = packed.length == 10 && read32(packed.bytes) == 0x02000041 &&
        read16((const unsigned char *)packed.bytes + 4) == 2 && read16((const unsigned char *)packed.bytes + 8) == 28;
    ok = ok && s1h_control_data_allowed(0x9403, @[@0x02000041], packed) &&
        !s1h_control_data_allowed(0x9404, @[@0x02000041], packed) && !s1h_control_pack(spec, @65536) &&
        !s1h_control_pack(spec, @(-1)) && !s1h_control_pack(spec, @2.8) && !s1h_control_pack(spec, @YES);
    NSMutableData *fixture = [NSMutableData dataWithLength:42]; unsigned char *b = fixture.mutableBytes;
    write32(b + 4, 6); write32(b + 28, 0x02000040); write16(b + 32, 28); write32(b + 34, 2); write16(b + 38, 28); write16(b + 40, 40);
    NSDictionary *parsed = s1h_control_parse_descriptor(fixture, spec, NULL);
    ok = ok && [parsed[@"current"] isEqual:@28] && [parsed[@"raw_options"] isEqual:@[@28,@40]];
    write32(b + 34, UINT32_MAX); ok = ok && !s1h_control_parse_descriptor(fixture, spec, NULL);
    write32(b + 4, UINT32_MAX); ok = ok && !s1h_control_parse_descriptor(fixture, spec, NULL);
    write32(b + 4, 4); ok = ok && !s1h_control_parse_descriptor(fixture, spec, NULL);
    ok = ok && !s1h_control_parse_descriptor([NSMutableData dataWithLength:31], spec, NULL) &&
        s1h_control_read_allowed(0x9108, @[@0x02000040,@0,@0]) &&
        !s1h_control_read_allowed(0x9108, @[@0x02000040,@1,@0]) &&
        s1h_control_read_allowed(0x9402, @[@0x02000030]) && s1h_control_read_allowed(0x9402, @[@0x02000021]) &&
        !s1h_control_read_allowed(0x9402, @[@0xDEADBEEF]) && !s1h_control_read_allowed(0x9402, @[@0x02000050]);
    printf("%s Control scalar packing, descriptor bounds, typed values and fixed read/write allowlists.\n", ok ? "PASS" : "FAIL");
    NSNumber *isoAuto = @(UINT32_MAX);
    NSData *isoPayload = s1h_control_pack(s1h_control_spec(@"iso"), isoAuto);
    BOOL isoOK = [s1h_control_value_label(@"iso", isoAuto) isEqualToString:@"AUTO"] &&
        [s1h_control_value_label(@"iso", @100) isEqualToString:@"100"] &&
        [s1h_control_value_label(@"shutter", isoAuto) isEqualToString:@"Bulb"] &&
        isoPayload.length == 12 && read32((const unsigned char *)isoPayload.bytes + 8) == UINT32_MAX;
    printf("%s ISO AUTO displays by name while retaining its four-byte camera value.\n", isoOK ? "PASS" : "FAIL");
    S1HControlFixtureTransport *whiteBalanceTransport = [S1HControlFixtureTransport new];
    whiteBalanceTransport.fixtureRequests = [NSMutableArray array];
    whiteBalanceTransport.synchronized = YES;
    whiteBalanceTransport.fixtureReplies = @[s1h_control_fixture_descriptor(0x02000051, 0x800c, 0x800b, 0x800c)];
    NSDictionary *whiteBalance = s1h_control_query(whiteBalanceTransport, s1h_control_spec(@"white_balance"));
    BOOL whiteBalanceOK = [whiteBalance[@"current"] isEqual:@0x800c] &&
        [whiteBalance[@"current_label"] isEqual:@"White Set 2"] &&
        [whiteBalance[@"options"] isEqual:@[@{@"value":@0x800b, @"label":@"White Set 1"},
                                               @{@"value":@0x800c, @"label":@"White Set 2"}]] &&
        [s1h_control_value_label(@"white_balance", @0x800d) isEqual:@"White Set 3"] &&
        [s1h_control_value_label(@"white_balance", @0x800e) isEqual:@"White Set 4"] &&
        [s1h_control_value_label(@"white_balance", @0x8fff) isEqual:@"0x8FFF"];
    printf("%s White balance presets have names and retain their camera values.\n", whiteBalanceOK ? "PASS" : "FAIL");
    BOOL setterOK = s1h_control_setter_self_test();
    printf("%s Settings use current choices and check actual read-back without retries.\n", setterOK ? "PASS" : "FAIL");
    BOOL driveModeOK = s1h_drive_mode_self_test();
    printf("%s Drive mode read-out, optional capability, malformed descriptor and setter rejection.\n", driveModeOK ? "PASS" : "FAIL");
    return ok && isoOK && whiteBalanceOK && setterOK && driveModeOK;
}
