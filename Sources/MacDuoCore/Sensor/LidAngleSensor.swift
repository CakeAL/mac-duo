//
//  LidAngleSensor.swift
//  MacDuo
//
//  Reads the MacBook lid-angle sensor (Apple VID 0x05AC / PID 0x8104) through
//  IOKit HID: a single-byte-pair little-endian value inside feature report 1.
//
//  Technique derived from samhenrigold/LidAngleSensor (MIT).
//

import Foundation
import IOKit.hid
import QuartzCore

/// Where the sensor stands on this machine.
public enum SensorAvailability: Equatable {
    /// Sensor found and feature report 1 is readable.
    case available
    /// Sensor HID node exists but exposes no readable angle report (seen on some M1/M2 Macs).
    case unsupportedInterface
    /// No matching HID device at all (desktop Mac, or HID node not present).
    case notFound

    public var displayText: String {
        switch self {
        case .available: "已连接"
        case .unsupportedInterface: "传感器节点存在，但无法读取角度"
        case .notFound: "未找到盖角传感器"
        }
    }
}

/// Polls the lid-angle sensor and publishes a smoothed angle in degrees.
///
/// 0° means the lid is closed, ~135°+ means fully open.
@MainActor
@Observable
public final class LidAngleSensor {

    // MARK: - Public state

    public private(set) var angle: Double = 110
    public private(set) var availability: SensorAvailability = .notFound
    public private(set) var tick: UInt = 0

    /// True while the reading has been confirmed as live hardware data.
    public var isAvailable: Bool { availability == .available }

    /// Human readable bucket, mainly for the menu bar tooltip.
    public var statusText: String {
        guard isAvailable else { return availability.displayText }
        return switch angle {
        case ..<5: "已合盖"
        case ..<45: "几乎合上"
        case ..<90: "半开"
        case ..<120: "基本打开"
        default: "完全打开"
        }
    }

    // MARK: - Private state

    nonisolated private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)
    private static let pollInterval: TimeInterval = 1.0 / 60.0
    private static let smoothing: Double = 0.28

    @ObservationIgnored private var device: IOHIDDevice?
    @ObservationIgnored private var deviceIsOpen = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var report = [UInt8](repeating: 0, count: 8)
    @ObservationIgnored private var smoothedAngle: Double?
    @ObservationIgnored private var consecutiveFailures = 0

    // MARK: - Lifecycle

    public init() {
        openDevice()
    }

    deinit {
        timer?.invalidate()
        if deviceIsOpen, let device {
            IOHIDDeviceClose(device, Self.noOptions)
        }
    }

    // MARK: - Control

    public func start() {
        guard timer == nil else { return }
        if device == nil {
            openDevice()
        }
        guard device != nil else { return }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // .common keeps polling alive while a menu or a drag is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-run hardware detection; used by the menu bar's "重新检测传感器".
    public func restart() {
        stop()
        closeDevice()
        smoothedAngle = nil
        consecutiveFailures = 0
        openDevice()
        start()
    }

    // MARK: - Device discovery

    private func openDevice() {
        guard let found = Self.findSensorDevice() else {
            availability = Self.sensorNodeExists() ? .unsupportedInterface : .notFound
            return
        }
        device = found
        availability = .available
        if !deviceIsOpen {
            deviceIsOpen = IOHIDDeviceOpen(found, Self.noOptions) == kIOReturnSuccess
        }
        if !deviceIsOpen {
            availability = .unsupportedInterface
        }
    }

    private func closeDevice() {
        if deviceIsOpen, let device {
            IOHIDDeviceClose(device, Self.noOptions)
        }
        deviceIsOpen = false
        device = nil
    }

    /// Probes the HID tree for the lid-angle sensor and returns the first node
    /// whose feature report 1 actually yields an angle.
    ///
    /// Several HID nodes share VID 0x05AC / PID 0x8104, so every candidate is
    /// tested by reading a report before being accepted.
    nonisolated private static func findSensorDevice() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, noOptions)
        guard IOHIDManagerOpen(manager, noOptions) == kIOReturnSuccess else { return nil }
        defer { IOHIDManagerClose(manager, noOptions) }

        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
        ] as CFDictionary)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }

        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, noOptions) == kIOReturnSuccess else { continue }

            var probe = [UInt8](repeating: 0, count: 8)
            var length = CFIndex(probe.count)
            let result = IOHIDDeviceGetReport(
                candidate,
                kIOHIDReportTypeFeature,
                1,
                &probe,
                &length
            )

            if result == kIOReturnSuccess, length >= 3 {
                // Keep the node open; the caller re-opens it (idempotent for IOKit).
                return candidate
            }
            IOHIDDeviceClose(candidate, noOptions)
        }

        return nil
    }

    /// True when the 0x8104 node exists at all, even if unreadable.
    nonisolated private static func sensorNodeExists() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, noOptions)
        guard IOHIDManagerOpen(manager, noOptions) == kIOReturnSuccess else { return false }
        defer { IOHIDManagerClose(manager, noOptions) }

        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
        ] as CFDictionary)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return !devices.isEmpty
    }

    // MARK: - Polling

    private func poll() {
        if !deviceIsOpen || device == nil {
            if tick % 120 == 0 {   // retry roughly twice a second
                closeDevice()
                openDevice()
            }
            tick &+= 1
            return
        }

        guard let device else { return }

        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            1,
            &report,
            &length
        )

        guard result == kIOReturnSuccess, length >= 3 else {
            consecutiveFailures += 1
            tick &+= 1
            if consecutiveFailures > 240 {
                // Device likely vanished (sleep/wake); rebuild it.
                restart()
            }
            return
        }

        consecutiveFailures = 0
        let raw = UInt16(report[2]) << 8 | UInt16(report[1])
        tick &+= 1

        let reading = Double(raw)
        if let previous = smoothedAngle {
            let next = previous + (reading - previous) * Self.smoothing
            smoothedAngle = next
            angle = next
        } else {
            smoothedAngle = reading
            angle = reading
        }
    }
}
