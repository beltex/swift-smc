//
// SMCKitTests.swift
// SMCKit
//
// The MIT License
//
// Copyright (C) 2015  beltex <http://beltex.github.io>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Cocoa
import XCTest
import SMCKit
import DiscRecording

/**
Notes

- Don't have a master list of what each Mac has (which fans, sensors, etc.) to
  check against
- Hard to validate return values, we can test that the calls don't fail, but not
  if the return values are correct necessarily. In some cases, can cross-check
  them via other APIs and tools (battery, powermetrics, etc.)
- See also powermetricsTests which cross-checks fan and CPU temperature


TODO

- Model specific tests?
- Could use the Intel Power Gadget API as a cross-check for CPU temperature.
  Problem is, requires installing a driver (kext) + framework. The need for a
  kext seems to be due to the rdmsr instruction, which can only be executed in
  kernel-space (temperature seems to be stored in a Model Specific Register -
  MSR). Could bundle it with SMCKit possibly to make that easier. Also, only
  works on second generation Intel Core 2 Duo chips and on.
*/
class SMCKitTests: XCTestCase {

    var smc = SMC()
    
    /// List of internal ODD devices
    var internalODD = [DRDevice]()
    
    
    // TODO: Setup once?
    override func setUp() {
        super.setUp()
        
        // Put setup code here. This method is called before the invocation of
        // each test method in the class.
        // TODO: If this fails no test should run
        smc.open()
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of
        // each test method in the class.
        smc.close()
        
        super.tearDown()
    }
    
    func testOpenConnectionTwice() {
        XCTAssertNotEqual(smc.open(), kIOReturnSuccess)
    }
    
    func testCloseConnectionTwice() {
        XCTAssertEqual(smc.close(), kIOReturnSuccess)
        XCTAssertNotEqual(smc.close(), kIOReturnSuccess)
        
        // Test that we can reopen and things still work
        smc.open()
        XCTAssertGreaterThanOrEqual(smc.getNumFans().numFans, UInt(1))
        XCTAssertEqual(smc.close(), kIOReturnSuccess)
    }
    
    func testTemperatureValues() {
        let temperatureSensors = smc.getAllValidTemperatureKeys()
        
        for sensor in temperatureSensors {
            let temperature = smc.getTemperature(sensor).tmp
            
            XCTAssertGreaterThan(temperature, -128.0)
            XCTAssertLessThan(temperature, 128.0)
        }
    }
    
    func testGetNumberFans() {
        // All Macs until now have at least 1 fan, except for the new 2015
        // MacBook (8,1)
        let result = smc.getNumFans()

        if modelName() == "MacBook8,1" {
            // Fanless
            XCTAssertEqual(result.numFans, 0)
        }
        else {
            XCTAssertGreaterThanOrEqual(result.numFans, 1)

            // Don't know the max number of fans, probably no more than 2 or 3,
            // but we'll give it some slack incase
            XCTAssertLessThanOrEqual(result.numFans, 4)
        }
    }
    
    func testIsKeyValid() {
        XCTAssertFalse(smc.isKeyValid("").valid)
        XCTAssertFalse(smc.isKeyValid("Vi").valid)
        XCTAssertFalse(smc.isKeyValid("Vim").valid)
        XCTAssertFalse(smc.isKeyValid("What is this new devilry?").valid)
        
        // We should be able to rely on always having these keys for now
        XCTAssertTrue(smc.isKeyValid("FNum").valid)     // Number of fans
        XCTAssertTrue(smc.isKeyValid("#KEY").valid)     // Number of keys
    }
    
    func testGetAllKeys() {
        var dict = smc.getAllKeys()
        XCTAssertFalse((dict.dict==nil), "Empty SMC ?!")
    }
    
    func testODD() {
        // Cross check via DiscRecording framework
        //
        // Handy Refs:
        // http://stackoverflow.com/questions/8770048/objective-c-drdevice-h
        // https://developer.apple.com/legacy/library/samplecode/DeviceListener/
        // http://stackoverflow.com/a/24049111
        
        let ODDStatusSMC = smc.isOpticalDiskDriveFull().flag
        let devicesCount = DRDevice.devices().count
        
        if (devicesCount == 0) {
            // TODO: This means that there are no ODD that have burn capability?
            //       Should be fine, as all Apple drives should have it
            println("No ODD devices")
            return
        }
        
        // To get the ODD object, need to reg for notification and wait. Since,
        // were looking for an internel device, should be instant.
        // See deviceAppeared() helper.
        DRNotificationCenter.currentRunLoopCenter().addObserver(self,
                                             selector: "deviceAppeared:",
                                             name: DRDeviceAppearedNotification,
                                             object: nil)
        
        // TODO: sleep here just incase for notification to be sent?

        
        // TODO: Ignoring the Mac Pro case for now, with 2 drives
        if (internalODD.count == 1) {
            let ODDStatus = internalODD[0].status()[DRDeviceMediaStateKey]
                                                                    as! NSString
            
            switch ODDStatus {
                case DRDeviceMediaStateMediaPresent:
                    XCTAssertTrue(ODDStatusSMC)
                case DRDeviceMediaStateInTransition:
                    // TODO: Should sleep and wait for state to become "stable",
                    //       DRDeviceStatusChangedNotification
                    // TODO: Throw a fail here?
                    break
                case DRDeviceMediaStateNone:
                    XCTAssertFalse(ODDStatusSMC)
                default:
                    // Unknown state - this should never happen. Only here to
                    // make compiler happy
                    break
            }
        }
        
        DRNotificationCenter.currentRunLoopCenter().removeObserver(self,
                                             name: DRDeviceAppearedNotification,
                                             object: nil)
    }
    
    func testBatteryPowerMethods() {
        var isLaptop    = false
        var ASPCharging = false
        var ASPCharged  = false
        
        // Check if machine is a laptop - if it is, we use the service to cross
        // check our values
        // TODO: Simplify I/O Kit calls here - can do it in a single call
        // TODO: What if its a MacBook with a removable battery and its out?
        var service = IOServiceGetMatchingService(kIOMasterPortDefault,
               IOServiceNameMatching("AppleSmartBattery").takeUnretainedValue())
        if (service != 0) {
            isLaptop = true
            
            // Getting these values to cross ref
            var prop = IORegistryEntryCreateCFProperty(service, "IsCharging",
                                                       kCFAllocatorDefault, 0)
            
            ASPCharging = prop.takeUnretainedValue() as! Int == 1 ? true : false
            
            
            prop = IORegistryEntryCreateCFProperty(service, "FullyCharged",
                                                   kCFAllocatorDefault, 0)
            
            ASPCharged = prop.takeUnretainedValue() as! Int == 1 ? true : false
        }
        
        
        let batteryPowered = smc.isBatteryPowered().flag
        let batteryOk      = smc.isBatteryOk().flag
        let ACPresent      = smc.isACPresent().flag
        let charging       = smc.isCharging().flag
        let numBatteries   = smc.maxNumberBatteries().count
        
        if (isLaptop) {
            // TODO: Is there any Mac that supports more then 1?
            XCTAssertEqual(numBatteries, UInt(1))
            
            /*
            Yeah, truth tables!... :)
            
            Note two specific cases we allow. First is to be battery powered and
            be fully charged. This could be true for a short period of time so
            we allow it. Second, much rarer occurrence, is AC powered and not
            charging or charged. This could be the case if the battery is pulled
            out.
            TODO: Though if the battery is out, AppleSmartBattery may not
                  show up...
            
            Can query WolframAlpha with "truth table" prefix to see it.
            
            Origin: (A ^ B) && ((B && !C) ^ (B <=> C)) && ((C ^ D) ^ (!C && !D))    

            CNF:    (!A || !B) && (A || B) && (B || !C) && (!C || !D)
            
            http://www.wolframalpha.com
            */
            let A = batteryPowered
            let B = ACPresent
            let C = charging && ASPCharging
            let D = ASPCharged
            
            XCTAssertTrue((!A || !B) && (A || B) && (B || !C) && (!C || !D))
        }
        else {
            XCTAssertFalse(batteryOk)
            XCTAssertFalse(batteryPowered)
            XCTAssertFalse(charging)
            XCTAssertTrue(ACPresent)
            XCTAssertEqual(numBatteries, UInt(0))
        }
        
        
        // TODO: Make sure this is called, even if tests above fail
        IOObjectRelease(service)
    }

    func testEncodeDecodeSMCKey() {
        let data: [(UInt32, String)] = [(1177567587, "F0Ac"),
                                        (1413689414, "TC0F")]

        for (encoded, decoded) in data {
            XCTAssertEqual(encoded, SMC.encodeSMCKey(decoded))
            XCTAssertEqual(decoded, SMC.decodeSMCKey(encoded))
        }
    }

    func testEncodeDecodeFPE2() {
        let data: [((UInt8, UInt8), UInt16)] = [((31, 64),  2000),
                                                ((56, 244), 3645),
                                                ((96, 220), 6199)]

        // NOTE: Compiler crash if for-in loop is used
        for var i = 0; i < data.count; ++i {
            let encoded = data[i].0
            let decoded = data[i].1

            // Surprisingly can't check equivalence for tuple as a whole
            let encodedTest = SMC.encodeFPE2(decoded)
            XCTAssert(encoded.0 == encodedTest.0 && encoded.1 == encodedTest.1)

            XCTAssertEqual(UInt(decoded), SMC.decodeFPE2(encoded))
        }
    }


    //--------------------------------------------------------------------------
    // MARK: HELPERS
    //--------------------------------------------------------------------------
    
    
    /**
    Callback on disc recording device (ODD) being found.
    
    NOTE: Must not be private ACL, otherwise selector can't be reached
    */
    func deviceAppeared(aNotification: NSNotification) {
        let newDevice  = aNotification.object as! DRDevice
        let deviceInfo = newDevice.info()
        
        let supportLevel = deviceInfo[DRDeviceSupportLevelKey] as! NSString
        let interconnect = deviceInfo[DRDevicePhysicalInterconnectLocationKey]
                                                                    as! NSString
        
        if (interconnect == DRDevicePhysicalInterconnectLocationInternal &&
            supportLevel == DRDeviceSupportLevelAppleShipping) {
            // The supposition here is that the SMC will only know about
            // internal Apple "made" ODD, and not a 3rd party one that someone
            // swapped in
            internalODD.append(newDevice)
        }
    }


    /// Get the model name of this machine. Same as "sysctl hw.model". Via
    /// SystemKit
    func modelName() -> String {
        let name: String
        var mib = [CTL_HW, HW_MODEL]

        // Max model name size not defined by sysctl. Instead we use io_name_t
        // via I/O Kit which can also get the model name
        var size = sizeof(io_name_t)

        var ptr    = UnsafeMutablePointer<io_name_t>.alloc(1)
        let result = sysctl(&mib, u_int(mib.count), ptr, &size, nil, 0)


        if result == 0 { name = String.fromCString(UnsafePointer(ptr))! }
        else           { name = String() }


        ptr.dealloc(1)

        return name
    }
}
