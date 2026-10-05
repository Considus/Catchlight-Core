//
//  LinuxTakeStoreContractTests.swift
//  CatchlightCoreTests
//
//  On Apple platforms XCTest finds `TakeStoreContractTests` in the
//  CatchlightCoreTestSupport library and runs its 31 tests against
//  `InMemoryTakeStore`. On Linux, test discovery looks only inside the test
//  target, so without this subclass the contract never runs there. Linux-only
//  so Apple platforms do not run it twice.
//

#if !canImport(Darwin)
import CatchlightCoreTestSupport

final class LinuxTakeStoreContractTests: TakeStoreContractTests {}
#endif
