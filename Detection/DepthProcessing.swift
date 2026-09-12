import Foundation
import simd

/// Camera-space depth image in meters, stored row-major (`meters[y * width + x]`).
///
/// Values that are non-finite or `<= 0` are invalid. This is the ARKit seam: later,
/// copy `ARFrame.sceneDepth.depthMap` (`CVPixelBuffer` Float32 meters) into `meters`
/// without importing ARKit or UIKit here.
struct DepthFrame: Equatable {
    let width: Int
    let height: Int
    /// Row-major depth samples in meters. Count must equal `width * height`.
    let meters: [Float]

    /// Pixel width and height as a SIMD vector.
    var size: SIMD2<Int> { SIMD2(width, height) }

    init(width: Int, height: Int, meters: [Float]) {
        precondition(width >= 0 && height >= 0, "DepthFrame dimensions must be non-negative")
        precondition(
            meters.count == width * height,
            "DepthFrame meters count (\(meters.count)) must equal width * height (\(width * height))"
        )
        self.width = width
        self.height = height
        self.meters = meters
    }

    /// Depth at pixel `(x, y)`, with `x` left-to-right and `y` top-to-bottom.
    subscript(x: Int, y: Int) -> Float {
        meters[y * width + x]
    }

    /// A sample is valid when it is a finite, strictly positive distance in meters.
    static func isValid(_ meters: Float) -> Bool {
        meters.isFinite && meters > 0
    }
}

/// Horizontal walk-path column, derived from a grid column index.
enum HazardDirection: Int, CaseIterable, Equatable {
    case left
    case center
    case right
}

/// Vertical band of the default 3-row grid. Row 0 is the top of the depth image.
enum DepthGridRow: Int, CaseIterable, Equatable {
    /// Top of the image — farther scene.
    case far = 0
    /// Middle band — typical obstacle / torso height.
    case mid = 1
    /// Bottom of the image — near-ground walking surface.
    case nearGround = 2
}

/// Aggregated samples for one cell of a depth grid.
struct DepthGridCell: Equatable {
    /// Closest valid depth in the cell, in meters. `nil` when every sample is invalid.
    let minMeters: Float?
    /// Fraction of samples in the cell that were valid, in `0...1`.
    let validFraction: Float
}

/// Rectangular grid of depth cells. The default layout is 3×3:
/// columns left / center / right, rows far / mid / near-ground (top to bottom).
struct DepthGrid: Equatable {
    let columns: Int
    let rows: Int
    /// Row-major cells, length `columns * rows`.
    let cells: [DepthGridCell]

    func cell(row: Int, column: Int) -> DepthGridCell {
        precondition(row >= 0 && row < rows, "row \(row) is outside 0..<\(rows)")
        precondition(column >= 0 && column < columns, "column \(column) is outside 0..<\(columns)")
        return cells[row * columns + column]
    }

    func cell(row: DepthGridRow, column: HazardDirection) -> DepthGridCell {
        cell(row: row.rawValue, column: column.rawValue)
    }

    /// Maps a column index onto left / center / right using this grid's column count.
    func direction(fromColumn column: Int) -> HazardDirection {
        DepthGridSampler.direction(fromColumn: column, columnCount: columns)
    }
}

/// Splits a `DepthFrame` into a coarse grid and reduces each cell to its nearest
/// valid sample plus coverage fraction.
enum DepthGridSampler {
    /// Samples `frame` into `columns` × `rows` cells (defaults to 3×3).
    ///
    /// Column 0 is left, then center, then right. Row 0 is far (top of the image),
    /// then mid, then near-ground (bottom). Remainders from uneven dimensions go
    /// to the later columns and rows.
    static func sample(_ frame: DepthFrame, columns: Int = 3, rows: Int = 3) -> DepthGrid {
        precondition(columns > 0 && rows > 0, "grid dimensions must be positive")

        var cells: [DepthGridCell] = []
        cells.reserveCapacity(columns * rows)

        for row in 0..<rows {
            let y0 = row * frame.height / rows
            let y1 = (row + 1) * frame.height / rows
            for column in 0..<columns {
                let x0 = column * frame.width / columns
                let x1 = (column + 1) * frame.width / columns
                cells.append(sampleCell(frame, x0: x0, x1: x1, y0: y0, y1: y1))
            }
        }

        return DepthGrid(columns: columns, rows: rows, cells: cells)
    }

    /// Maps a column index onto left / center / right.
    ///
    /// For the default 3-column grid this is `0 → left`, `1 → center`, `2 → right`.
    /// Other column counts are split into thirds.
    static func direction(fromColumn column: Int, columnCount: Int = 3) -> HazardDirection {
        precondition(columnCount > 0, "columnCount must be positive")
        precondition(column >= 0 && column < columnCount, "column \(column) is outside 0..<\(columnCount)")
        switch (column * 3) / columnCount {
        case 0:
            return .left
        case 1:
            return .center
        default:
            return .right
        }
    }

    private static func sampleCell(
        _ frame: DepthFrame,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int
    ) -> DepthGridCell {
        let total = (x1 - x0) * (y1 - y0)
        guard total > 0 else {
            return DepthGridCell(minMeters: nil, validFraction: 0)
        }

        var validCount = 0
        var minMeters: Float = .infinity

        for y in y0..<y1 {
            let rowStart = y * frame.width
            for x in x0..<x1 {
                let value = frame.meters[rowStart + x]
                guard DepthFrame.isValid(value) else { continue }
                validCount += 1
                minMeters = simd_min(minMeters, value)
            }
        }

        return DepthGridCell(
            minMeters: validCount > 0 ? minMeters : nil,
            validFraction: Float(validCount) / Float(total)
        )
    }
}

/// Metres in a gravity-aligned frame: x = across path, y = above ground,
/// z = forward along the smoothed walking direction (or camera heading at rest).
struct CorridorSample {
    let position: SIMD3<Float>
}

struct CorridorGeometry {
    var configuration: DetectionConfiguration = .standard

    func contains(_ point: SIMD3<Float>, cameraHeight: Float) -> Bool {
        abs(point.x) <= configuration.corridorHalfWidth && point.z >= configuration.corridorNear
            && point.z <= configuration.searchDistance && point.y >= -configuration.corridorBelowGround
            && point.y <= cameraHeight + configuration.corridorAboveCamera
    }

    /// Ray-box intersection selects only pixels projecting into the physical corridor.
    /// Invalid depth for an intersecting ray still contributes to expected coverage.
    func intersects(origin: SIMD3<Float>, direction: SIMD3<Float>, cameraHeight: Float) -> Bool {
        let lower = SIMD3<Float>(-configuration.corridorHalfWidth, -configuration.corridorBelowGround, configuration.corridorNear)
        let upper = SIMD3<Float>(configuration.corridorHalfWidth, cameraHeight + configuration.corridorAboveCamera, configuration.searchDistance)
        var entry: Float = 0
        var exit: Float = .infinity
        for axis in 0..<3 {
            if abs(direction[axis]) < 0.00001 {
                if origin[axis] < lower[axis] || origin[axis] > upper[axis] { return false }
            } else {
                let a = (lower[axis] - origin[axis]) / direction[axis]
                let b = (upper[axis] - origin[axis]) / direction[axis]
                entry = max(entry, min(a, b))
                exit = min(exit, max(a, b))
                if exit < entry { return false }
            }
        }
        return exit > 0
    }

    static func downPitch(forward: SIMD3<Float>) -> Float {
        asin(max(-1, min(1, -simd_normalize(forward).y))) * 180 / .pi
    }

    func guidance(pitch: Float) -> String? {
        if pitch > configuration.maximumDownPitch { return "Raise phone slightly" }
        if pitch < -configuration.maximumUpPitch { return "Point camera toward the path" }
        return nil
    }
}

enum CorridorDetector {
    static func analyze(samples: [CorridorSample], expected: Int, speed: Float,
                        cameraHeight: Float, configuration: DetectionConfiguration = .standard,
                        safetyProfile: SafetyProfile = .general) -> DetectionResult? {
        var configuration = configuration
        configuration.earlyDistance = max(configuration.earlyDistance, 3 * safetyProfile.warningDistanceMultiplier)
        guard expected > 0 else { return nil }
        let valid = samples.filter { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite }
        let coverage = Float(valid.count) / Float(expected)
        guard coverage >= configuration.minimumCoverage else { return nil }
        let geometry = CorridorGeometry(configuration: configuration)
        let path = valid.map(\.position).filter { geometry.contains($0, cameraHeight: cameraHeight) }
        guard path.count >= configuration.minimumHazardSamples else { return nil }
        let ground = path.filter { abs($0.y) <= configuration.groundTolerance }
        let obstacles = path.filter { $0.y > configuration.minimumObstacleHeight }
        let belowGround = path.filter { $0.y < -configuration.dropHeight }

        // Require a compact depth cluster. A global percentile can miss a small,
        // close object when most other pixels belong to a distant wall.
        func nearestSupport(_ values: [SIMD3<Float>]) -> SIMD3<Float>? {
            let sorted = values.sorted { $0.z < $1.z }
            let count = configuration.minimumHazardSamples
            guard sorted.count >= count else { return nil }
            for start in 0...(sorted.count - count) {
                let end = start + count - 1
                if sorted[end].z - sorted[start].z <= configuration.hazardSupportSpan {
                    let mean = sorted[start...end].reduce(SIMD3<Float>.zero, +) / Float(count)
                    return SIMD3<Float>(mean.x, mean.y, sorted[end].z)
                }
            }
            return nil
        }
        let groundDistances = ground.map(\.z).sorted()
        let observedDistance = groundDistances.count >= configuration.minimumHazardSamples
            ? groundDistances[groundDistances.count - configuration.minimumHazardSamples] : 0
        var candidates: [HazardObservation] = []
        var supports: [Hazard: SIMD3<Float>] = [:]
        if let obstacle = nearestSupport(obstacles) {
            let hazard: Hazard = obstacle.z <= Hazard.tooClose.baseDistance * safetyProfile.warningDistanceMultiplier ? .tooClose : .obstacle
            candidates.append(HazardObservation(hazard: hazard, distance: obstacle.z))
            supports[hazard] = obstacle
        }
        if let lower = nearestSupport(belowGround) {
            // Only supporting ground *before* the lower surface belongs to this edge.
            let beforeEdge = ground.filter { $0.z < lower.z }
            let hasNearSupport = beforeEdge.filter { $0.z < configuration.groundSupportDistance }.count >= configuration.minimumHazardSamples
            if hasNearSupport {
                let ordered = beforeEdge.map(\.z).sorted()
                let edgeDistance = ordered[ordered.count - configuration.minimumHazardSamples]
                candidates.append(HazardObservation(hazard: .dropOff, distance: edgeDistance))
                supports[.dropOff] = SIMD3<Float>(lower.x, 0, edgeDistance)
            } else if candidates.isEmpty { return nil }
        }
        // Seeing side surfaces alone is not evidence that the walking path is clear.
        if candidates.isEmpty && ground.count < configuration.minimumHazardSamples { return nil }
        let assessment = RiskEngine.assess(hazards: candidates,
            movementState: Movement(speed: speed, configuration: configuration), safetyProfile: safetyProfile, configuration: configuration)
        return DetectionResult(assessment: assessment,
            coverage: min(1, coverage), nearbyFraction: Float(obstacles.count) / Float(max(1, valid.count)),
            observedGroundDistance: observedDistance, supportPosition: supports[assessment.hazard])
    }
}

/// Fits a horizontal floor in gravity-aligned world coordinates. The estimate is
/// acquired only while still, then frozen so walking toward lower stairs cannot
/// silently redefine the landing as the current floor.
struct FloorEstimator {
    private(set) var floorY: Float?
    private(set) var progress: Double = 0
    private(set) var supportCount = 0
    private(set) var isAmbiguous = false
    private var pendingHeights: [Float] = []
    private var startedAt: Double?
    private var lastTimestamp: Double?

    mutating func reset() { self = FloorEstimator() }

    func phoneHeight(at cameraPosition: SIMD3<Float>) -> Float? {
        floorY.map { cameraPosition.y - $0 }
    }

    mutating func update(points: [SIMD3<Float>], cameraPosition: SIMD3<Float>, heading: SIMD3<Float>,
                         speed: Float, pitch: Float, orientationStable: Bool, timestamp: Double,
                         configuration: DetectionConfiguration = .standard) {
        guard floorY == nil else { return }
        isAmbiguous = false
        let continuous = lastTimestamp.map { timestamp > $0 && timestamp - $0 <= configuration.maximumSampleGap } ?? false
        lastTimestamp = timestamp
        guard speed < configuration.calibrationSpeed, orientationStable,
              configuration.canCalibrate(pitch: pitch) else {
            clearPending()
            return
        }
        if !continuous { clearPending() }
        let right = simd_cross(heading, SIMD3<Float>(0, 1, 0))
        let candidates = points.filter { point in
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return false }
            let delta = point - cameraPosition
            let forward = simd_dot(delta, heading)
            let height = -delta.y
            return height >= configuration.minimumCameraHeight && height <= configuration.maximumCameraHeight
                && abs(simd_dot(delta, right)) <= 0.8
                && forward >= configuration.floorCalibrationNear && forward <= configuration.floorCalibrationFar
        }
        guard candidates.count >= configuration.floorMinimumSamples else { clearPending(); return }

        // Fixed gravity normal: search height bins rather than fitting arbitrary
        // planes that could select a wall. Neighbour bins avoid boundary artifacts.
        let binWidth = configuration.floorFitTolerance * 2
        var bins: [Int: [SIMD3<Float>]] = [:]
        for point in candidates { bins[Int(floor(point.y / binWidth)), default: []].append(point) }
        var fits: [(height: Float, count: Int)] = []
        for key in bins.keys.sorted() {
            let neighbourhood = (bins[key - 1] ?? []) + (bins[key] ?? []) + (bins[key + 1] ?? [])
            let heights = neighbourhood.map(\.y).sorted()
            let center = heights[heights.count / 2]
            let inliers = neighbourhood.filter { abs($0.y - center) <= configuration.floorFitTolerance }
            guard inliers.count >= configuration.floorMinimumSamples,
                  Float(inliers.count) / Float(candidates.count) >= configuration.floorMinimumFraction else { continue }
            let lateral = inliers.map { simd_dot($0 - cameraPosition, right) }.sorted()
            let forward = inliers.map { simd_dot($0 - cameraPosition, heading) }.sorted()
            let low = inliers.count / 10, high = inliers.count - 1 - low
            guard lateral[high] - lateral[low] >= configuration.floorMinimumWidth,
                  forward[high] - forward[low] >= configuration.floorMinimumLength else { continue }
            var cells = Set<SIMD2<Int>>()
            for point in inliers {
                let delta = point - cameraPosition
                cells.insert(SIMD2<Int>(Int(floor(simd_dot(delta, right) / configuration.floorCellSize)),
                    Int(floor(simd_dot(delta, heading) / configuration.floorCellSize))))
            }
            guard cells.count >= configuration.floorMinimumCells else { continue }
            if let index = fits.firstIndex(where: { abs($0.height - center) <= configuration.floorFitTolerance * 2 }) {
                if fits[index].count < inliers.count { fits[index] = (center, inliers.count) }
            } else { fits.append((center, inliers.count)) }
        }
        fits.sort { $0.count > $1.count }
        guard let best = fits.first else { clearPending(); return }
        if fits.dropFirst().contains(where: {
            abs($0.height - best.height) > configuration.groundTolerance &&
                Float($0.count) >= Float(best.count) * configuration.competingFloorRatio
        }) {
            clearPending()
            isAmbiguous = true
            return
        }
        let candidateY = best.height
        if let initial = pendingHeights.first, abs(candidateY - initial) > configuration.floorFitTolerance {
            clearPending()
        }
        supportCount = best.count
        if startedAt == nil { startedAt = timestamp }
        pendingHeights.append(candidateY)
        progress = min(1, (timestamp - (startedAt ?? timestamp)) / configuration.calibrationDuration)
        if progress >= 1 && pendingHeights.count >= 5 {
            let ordered = pendingHeights.sorted()
            floorY = ordered[ordered.count / 2]
            pendingHeights.removeAll()
        }
    }

    private mutating func clearPending() {
        pendingHeights.removeAll()
        startedAt = nil
        progress = 0
        supportCount = 0
    }
}

/// Camera depth is axial z. Do not normalize this ray before multiplying by depth.
enum DepthProjection {
    static func worldRay(sensorPixel: SIMD2<Float>, intrinsics: simd_float3x3,
                         cameraTransform: simd_float4x4) -> SIMD3<Float> {
        let cameraRay = SIMD4<Float>((sensorPixel.x - intrinsics.columns.2.x) / intrinsics.columns.0.x,
            -(sensorPixel.y - intrinsics.columns.2.y) / intrinsics.columns.1.y, -1, 0)
        let ray = cameraTransform * cameraRay
        return SIMD3<Float>(ray.x, ray.y, ray.z)
    }
}
