/* Panasonic lens drive uses two opposite low-speed modes, 2 and 3.
 * The controls name the relative directions without an absolute distance. */

static const uint16_t S1HFocusDriveOpcode = 0x9416;
static const uint32_t S1HFocusDriveSelector = 0x03010011;
static const double S1HFocusJogSeconds = 0.12;
static const double S1HFocusTransactionSeconds = 1.2;

static void bounded_pause(double seconds);

static BOOL s1h_focus_data_allowed(uint16_t opcode, NSArray<NSNumber *> *parameters, NSData *data) {
    if (opcode != S1HFocusDriveOpcode || parameters.count != 1 ||
        ![parameters.firstObject isEqual:@(S1HFocusDriveSelector)] || data.length != 10) return NO;
    const unsigned char *bytes = data.bytes;
    uint16_t step = read16(bytes + 8);
    return read32(bytes) == S1HFocusDriveSelector && read32(bytes + 4) == 2 &&
        (step == 0 || step == 2 || step == 3);
}

static NSData *s1h_focus_drive_data(uint16_t step) {
    unsigned char bytes[10];
    write32(bytes, S1HFocusDriveSelector);
    write32(bytes + 4, 2);
    write16(bytes + 8, step);
    return [NSData dataWithBytes:bytes length:sizeof bytes];
}

static NSDictionary *s1h_focus_jog(NativePreviewTransport *transport, id direction) {
    uint16_t step = [direction isEqual:@"a"] ? 2 : ([direction isEqual:@"b"] ? 3 : 0);
    if (!step || StopRequested || !transport.synchronized)
        return @{@"status":@"rejected", @"message":@"A focus adjustment requires a valid direction and an idle camera connection."};
    NSDictionary *focus = s1h_control_query(transport, s1h_control_spec(@"focus_mode"));
    if (![focus[@"current"] isEqual:@3] || StopRequested || !transport.synchronized)
        return @{@"status":@"rejected", @"message":@"Use the camera's MF mode before adjusting focus remotely."};

    double previousBudget = transport.transactionBudget;
    transport.transactionBudget = S1HFocusTransactionSeconds;
    NSArray<NSNumber *> *parameters = @[@(S1HFocusDriveSelector)];
    PreviewReply *drive = [transport request:S1HFocusDriveOpcode parameters:parameters
                                 dataExpected:NO dataOut:s1h_focus_drive_data(step)];
    PreviewReply *stop = nil;
    if (drive.code == 0x2001 && transport.synchronized) {
        bounded_pause(S1HFocusJogSeconds);
        // A stop is still required if the user cancelled during the jog.
        stop = [transport request:S1HFocusDriveOpcode parameters:parameters
                       dataExpected:NO dataOut:s1h_focus_drive_data(0)];
    }
    transport.transactionBudget = previousBudget;
    if (!drive || !transport.synchronized || (drive.code == 0x2001 && stop.code != 0x2001))
        return @{@"status":@"outcome_unknown", @"message":@"The lens-drive outcome could not be confirmed. Check the camera before moving focus again."};
    if (drive.code != 0x2001)
        return @{@"status":@"error", @"message":[NSString stringWithFormat:@"The camera declined the focus command (0x%04X).", drive.code]};
    return @{@"status":@"ok", @"message":@"The camera accepted the focus adjustment and stop. Check focus in live view."};
}

@interface S1HFocusFixtureTransport : S1HControlFixtureTransport
@end

@implementation S1HFocusFixtureTransport
- (PreviewReply *)request:(uint16_t)opcode parameters:(NSArray<NSNumber *> *)parameters
             dataExpected:(BOOL)expected dataOut:(NSData *)dataOut {
    PreviewReply *reply = [super request:opcode parameters:parameters dataExpected:expected dataOut:dataOut];
    if (reply && opcode == S1HFocusDriveOpcode && self.fixtureRequests.count == 2) StopRequested = 1;
    return reply;
}
@end

static BOOL s1h_focus_self_test(void) {
    NSArray *selector = @[@(S1HFocusDriveSelector)];
    const unsigned char expected[] = {0x11, 0x00, 0x01, 0x03, 2, 0, 0, 0, 2, 0};
    NSData *smallStep = s1h_focus_drive_data(2);
    BOOL ok = [smallStep isEqualToData:[NSData dataWithBytes:expected length:sizeof expected]] &&
        s1h_focus_data_allowed(0x9416, selector, smallStep) &&
        s1h_focus_data_allowed(0x9416, selector, s1h_focus_drive_data(3)) &&
        s1h_focus_data_allowed(0x9416, selector, s1h_focus_drive_data(0)) &&
        !s1h_focus_data_allowed(0x9416, selector, s1h_focus_drive_data(1)) &&
        !s1h_focus_data_allowed(0x9416, selector, s1h_focus_drive_data(4)) &&
        !s1h_focus_data_allowed(0x9416, @[@0x03010012], smallStep) &&
        !s1h_focus_data_allowed(0x9416, @[@(S1HFocusDriveSelector), @0], smallStep) &&
        !s1h_focus_data_allowed(0x9405, selector, smallStep) &&
        !s1h_focus_data_allowed(0x9416, selector, [smallStep subdataWithRange:NSMakeRange(0, 9)]);
    S1HControlFixtureTransport *transport = [S1HControlFixtureTransport new];
    transport.synchronized = YES;
    transport.transactionBudget = 3.5;
    transport.fixtureRequests = [NSMutableArray array];
    PreviewReply *manual = s1h_control_fixture_descriptor(0x02000071, 3, 3, 4);
    PreviewReply *autofocus = s1h_control_fixture_descriptor(0x02000071, 4, 3, 4);
    PreviewReply *accepted = s1h_control_fixture_reply(0x2001, nil);
    PreviewReply *declined = s1h_control_fixture_reply(0x2005, nil);
    NSArray *readMode = @[@0x9108, @[@0x02000071, @0, @0], @YES, NSNull.null];
    NSArray *driveA = @[@0x9416, selector, @NO, smallStep];
    NSArray *driveB = @[@0x9416, selector, @NO, s1h_focus_drive_data(3)];
    NSArray *stopDrive = @[@0x9416, selector, @NO, s1h_focus_drive_data(0)];

    ok = ok && [s1h_focus_jog(transport, @4)[@"status"] isEqual:@"rejected"] && !transport.fixtureRequests.count;
    transport.fixtureReplies = @[autofocus];
    ok = ok && [s1h_focus_jog(transport, @"a")[@"status"] isEqual:@"rejected"] &&
        [transport.fixtureRequests isEqual:@[readMode]];
    [transport.fixtureRequests removeAllObjects];
    transport.fixtureReplies = @[manual, accepted, accepted];
    ok = ok && [s1h_focus_jog(transport, @"a")[@"status"] isEqual:@"ok"] &&
        [transport.fixtureRequests isEqual:@[readMode, driveA, stopDrive]] && transport.transactionBudget == 3.5;
    [transport.fixtureRequests removeAllObjects];
    transport.fixtureReplies = @[manual, declined];
    ok = ok && [s1h_focus_jog(transport, @"a")[@"status"] isEqual:@"error"] &&
        [transport.fixtureRequests isEqual:@[readMode, driveA]];
    [transport.fixtureRequests removeAllObjects];
    transport.fixtureReplies = @[manual, accepted, declined];
    ok = ok && [s1h_focus_jog(transport, @"b")[@"status"] isEqual:@"outcome_unknown"] &&
        [transport.fixtureRequests isEqual:@[readMode, driveB, stopDrive]];
    [transport.fixtureRequests removeAllObjects];
    transport.fixtureReplies = @[manual, NSNull.null];
    ok = ok && [s1h_focus_jog(transport, @"b")[@"status"] isEqual:@"outcome_unknown"] &&
        !transport.synchronized && [transport.fixtureRequests isEqual:@[readMode, driveB]] && transport.transactionBudget == 3.5;

    S1HFocusFixtureTransport *cancelled = [S1HFocusFixtureTransport new];
    cancelled.synchronized = YES;
    cancelled.fixtureRequests = [NSMutableArray array];
    cancelled.fixtureReplies = @[manual, accepted, accepted];
    sig_atomic_t priorStop = StopRequested;
    NSDictionary *result = s1h_focus_jog(cancelled, @"b");
    BOOL stopSentAfterCancellation = StopRequested && [cancelled.fixtureRequests isEqual:@[readMode, driveB, stopDrive]];
    StopRequested = priorStop;
    return ok && [result[@"status"] isEqual:@"ok"] && stopSentAfterCancellation;
}
