import Foundation

/// When the "unusually similar day-to-day" monotony warning shows. Load &
/// Trajectory and the Training Load screen both ask here, so the two screens
/// never disagree about the same week.
///
/// Foster (1998, Med Sci Sports Exerc 30(7):1164-1168) related illness to
/// weeks of high strain (weekly load × monotony) and named monotony (mean ÷
/// SD of the week's daily load) above 2.0 as the marker of a week whose
/// load was not varied. So the warning needs both: monotony over
/// `RecoveryScoreConstants.Training.monotonyThreshold` and strain over
/// `RecoveryScoreConstants.Training.strainThreshold`. A light week of
/// similar sessions is not the pattern Foster describes.
enum FosterMonotonyWarning {
    /// Whether the week ending on `referenceDate` raises the warning
    /// (`RecoveryScoreCalculator.fosterMonotonyStrain` over its seven days).
    static func isRaised(dailyLoad: [Date: Double], referenceDate: Date = Date()) -> Bool {
        guard let foster = RecoveryScoreCalculator.fosterMonotonyStrain(dailyTrimp: dailyLoad, referenceDate: referenceDate) else {
            return false
        }
        return isRaised(foster)
    }

    /// Whether a computed monotony and strain raise the warning.
    static func isRaised(_ foster: (monotony: Double, strain: Double)) -> Bool {
        foster.monotony > RecoveryScoreConstants.Training.monotonyThreshold
            && foster.strain > RecoveryScoreConstants.Training.strainThreshold
    }
}
