#!/usr/bin/env swift
/*
 * Cuascape Runner - Metal shader viewer
 * Based on "Seascape" by Alexander Alekseev aka TDM - 2014
 * Ported to Metal for Cuaview by Prava (2024)
 * Usage: swift cuascape_runner.swift
 */

import Cocoa
import Metal
import MetalKit

// Uniforms struct matching the Metal shader
struct Uniforms {
    var time: Float
    var resolution: SIMD2<Float>
    var mouse: SIMD2<Float>
}

class CuascapeRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    var uniforms = Uniforms(time: 0, resolution: SIMD2<Float>(800, 600), mouse: SIMD2<Float>(0, 0))
    let startTime: CFAbsoluteTime

    init?(metalView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            print("Metal is not supported on this device")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.startTime = CFAbsoluteTimeGetCurrent()
        metalView.device = device
        metalView.colorPixelFormat = .bgra8Unorm

        // Load shader from file
        let shaderPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("cuascape.metal")

        guard let shaderSource = try? String(contentsOf: shaderPath, encoding: .utf8) else {
            print("Failed to load cuascape.metal")
            return nil
        }

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let vertexFunction = library.makeFunction(name: "vertexShader"),
                  let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
                print("Failed to find shader functions")
                return nil
            }

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat

            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create pipeline state: \(error)")
            return nil
        }

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        uniforms.resolution = SIMD2<Float>(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        uniforms.time = Float(CFAbsoluteTimeGetCurrent() - startTime)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        renderEncoder.endEncoding()

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }
}

class CuascapeView: MTKView {
    var lastMouseLocation: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseMoved(with event: NSEvent) {
        lastMouseLocation = event.locationInWindow
        if let renderer = delegate as? CuascapeRenderer {
            renderer.uniforms.mouse = SIMD2<Float>(Float(lastMouseLocation.x), Float(lastMouseLocation.y))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var metalView: CuascapeView!
    var renderer: CuascapeRenderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowRect = NSRect(x: 100, y: 100, width: 1280, height: 720)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cuascape - Metal Shader"
        window.center()

        metalView = CuascapeView(frame: windowRect)
        metalView.preferredFramesPerSecond = 60

        guard let renderer = CuascapeRenderer(metalView: metalView) else {
            NSApp.terminate(nil)
            return
        }

        self.renderer = renderer
        metalView.delegate = renderer

        window.contentView = metalView
        window.makeKeyAndOrderFront(nil)
        window.acceptsMouseMovedEvents = true

        // Set up tracking area for mouse movement
        let trackingArea = NSTrackingArea(
            rect: metalView.bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: metalView,
            userInfo: nil
        )
        metalView.addTrackingArea(trackingArea)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
