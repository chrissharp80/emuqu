@testable import Emuqu
import XCTest

final class StatisticsTests: XCTestCase {
    // MARK: - Mean

    func testMeanEmptyArray() {
        XCTAssertEqual(Statistics.mean([]), 0)
    }

    func testMeanSingleElement() {
        XCTAssertEqual(Statistics.mean([42.0]), 42.0)
    }

    func testMeanKnownValues() {
        XCTAssertEqual(Statistics.mean([1, 2, 3, 4, 5]), 3.0, accuracy: 1e-10)
    }

    func testMeanNegativeValues() {
        XCTAssertEqual(Statistics.mean([-10, 10]), 0.0, accuracy: 1e-10)
    }

    func testMeanLargeArray() {
        let values = (1 ... 1000).map { Double($0) }
        XCTAssertEqual(Statistics.mean(values), 500.5, accuracy: 1e-6)
    }

    // MARK: - Sample Variance & Standard Deviation

    func testSampleVarianceEmptyArray() {
        XCTAssertEqual(Statistics.sampleVariance([]), 0)
    }

    func testSampleVarianceSingleElement() {
        XCTAssertEqual(Statistics.sampleVariance([5.0]), 0)
    }

    func testSampleVarianceKnownValues() {
        // [2, 4, 4, 4, 5, 5, 7, 9] → mean=5, variance=4.571...
        let values = [2.0, 4, 4, 4, 5, 5, 7, 9]
        XCTAssertEqual(Statistics.sampleVariance(values), 4.571428571, accuracy: 1e-6)
    }

    func testSampleStandardDeviationKnownValues() {
        let values = [2.0, 4, 4, 4, 5, 5, 7, 9]
        let expected = sqrt(4.571428571)
        XCTAssertEqual(Statistics.sampleStandardDeviation(values), expected, accuracy: 1e-6)
    }

    func testSampleStandardDeviationUniform() {
        // All same values → SD = 0
        let values = [Double](repeating: 42.0, count: 100)
        XCTAssertEqual(Statistics.sampleStandardDeviation(values), 0, accuracy: 1e-10)
    }

    // MARK: - Root Mean Square

    func testRMSEmpty() {
        XCTAssertEqual(Statistics.rootMeanSquare([]), 0)
    }

    func testRMSKnownValues() {
        // RMS of [3, 4] = sqrt((9+16)/2) = sqrt(12.5) ≈ 3.536
        XCTAssertEqual(Statistics.rootMeanSquare([3.0, 4.0]), sqrt(12.5), accuracy: 1e-10)
    }

    func testRMSAllEqual() {
        // RMS of constant = that constant
        XCTAssertEqual(Statistics.rootMeanSquare([5, 5, 5, 5]), 5.0, accuracy: 1e-10)
    }

    // MARK: - Coefficient of Variation

    func testCVZeroMean() {
        // [-1, 1] has mean 0 → CV is nil
        XCTAssertNil(Statistics.coefficientOfVariation([-1.0, 1.0]))
    }

    func testCVKnownValues() throws {
        // [10, 10, 10] → SD=0, mean=10 → CV=0
        let cv = try XCTUnwrap(Statistics.coefficientOfVariation([10, 10, 10]))
        XCTAssertEqual(cv, 0, accuracy: 1e-10)
    }

    func testCVPositiveValues() throws {
        let values = [100.0, 200.0]
        let cv = Statistics.coefficientOfVariation(values)
        XCTAssertNotNil(cv)
        XCTAssertGreaterThan(try XCTUnwrap(cv), 0)
    }

    // MARK: - Linear Regression

    func testLinearRegressionPerfectLine() throws {
        // y = 2x + 1
        let x = [1.0, 2, 3, 4, 5]
        let y = [3.0, 5, 7, 9, 11]
        let result = Statistics.linearRegression(x: x, y: y)
        XCTAssertNotNil(result)
        XCTAssertEqual(try XCTUnwrap(result?.slope), 2.0, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(result?.intercept), 1.0, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(result?.r2), 1.0, accuracy: 1e-10)
    }

    func testLinearRegressionInsufficientData() {
        XCTAssertNil(Statistics.linearRegression(x: [1.0], y: [1.0]))
        XCTAssertNil(Statistics.linearRegression(x: [], y: []))
    }

    func testLinearRegressionMismatchedArrays() {
        XCTAssertNil(Statistics.linearRegression(x: [1, 2, 3], y: [1, 2]))
    }

    func testLinearRegressionConstantX() {
        // All x values the same → degenerate
        XCTAssertNil(Statistics.linearRegression(x: [5, 5, 5], y: [1, 2, 3]))
    }

    func testLinearRegressionR2LowForNoise() throws {
        // y uncorrelated with x
        let x = [1.0, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let y = [5.0, 3, 8, 1, 7, 2, 9, 4, 6, 10]
        let result = Statistics.linearRegression(x: x, y: y)
        XCTAssertNotNil(result)
        XCTAssertLessThan(try XCTUnwrap(result?.r2), 0.5, "R² should be low for uncorrelated data")
    }

    // MARK: - Array Convenience Extensions

    func testArrayMean() {
        XCTAssertEqual([1.0, 2.0, 3.0].mean, 2.0, accuracy: 1e-10)
    }

    func testArraySampleSD() {
        let values = [2.0, 4, 4, 4, 5, 5, 7, 9]
        XCTAssertEqual(values.sampleSD, Statistics.sampleStandardDeviation(values), accuracy: 1e-10)
    }

    func testArrayRMS() {
        XCTAssertEqual([3.0, 4.0].rms, sqrt(12.5), accuracy: 1e-10)
    }
}
