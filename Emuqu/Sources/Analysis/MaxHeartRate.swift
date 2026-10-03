import Foundation

/// Age-predicted maximum heart rate.
///
/// ## Why this is its own type
///
/// This number is not cosmetic. It anchors HR-reserve in the Banister TRIMP
/// exponential, so it sets how much every workout contributes to training load,
/// and it defines every HR zone boundary shown to the user.
///
/// Inline in `UserSettings.effectiveMaxHR` as a formula wrapped around
/// a `Calendar.current` age derivation, it mixed a pure, citable equation with
/// the one part of the calculation that depends on ambient process state — and
/// `Calendar.current` follows the process-global time zone, which ten test
/// classes mutate. The formula could only be tested through a date, so a test
/// of *arithmetic* was order-dependent (observed failing in a full suite run and
/// passing alone).
///
/// Separated here: the equation takes an age, and the age derivation takes an
/// explicit calendar and reference date.
enum MaxHeartRate {
    /// Tanaka, Monahan & Seals (JACC 2001;37(1):153-156): HRmax ≈ 208 − 0.7·age.
    ///
    /// Not `220 − age`: that form under-estimates HRmax
    /// for older adults, which inflates heart-rate reserve and over-weights easy
    /// activity — a 4-mile walk reads as a ~100-TRIMP session and grounds a
    /// low-CTL user at TSB −30.
    ///
    /// Clamped to 130…220 as a sanity bound on the INPUT, not the output.
    ///
    /// The floor is NOT 150. "Below 150 the zones collapse into each other"
    /// is not true: zones are percentages of
    /// HRmax, so they scale rather than collapse. What a 150 floor actually does
    /// is bind from about age 83 upward — Tanaka gives 150 at 83 — and hold
    /// HRmax ABOVE the formula for anyone older. That overstates HRmax,
    /// understates heart-rate reserve, and makes their sessions read easier
    /// than they were. Exactly backwards for the group least served by a
    /// population equation.
    ///
    /// 130 is a pragmatic APPLICATION bound, not a corrected or derived value,
    /// and there is no evidence for 130 specifically.
    ///
    /// It is NOT true that 130 "only catches input that was never an age".
    /// The formula reaches 130 at
    /// about age 111, and the oldest verified human lived to 122, so ages
    /// 112–122 are real and DO get clamped. The population is vanishingly
    /// small and the equation was fitted on subjects aged 20–86, so it is
    /// extrapolating badly there anyway — but "no real age" would be an
    /// overstated justification for an arbitrary number.
    ///
    /// What actually matters is upstream of the clamp. Tanaka was fitted on
    /// 18,712 subjects aged 20–86 and predicts the POPULATION mean well; for
    /// an individual the spread is wide, with reported standard deviations
    /// around 7–11 bpm and error estimates commonly quoted as ±7–12 bpm. At
    /// that spread the clamp is noise next to the estimate itself. A
    /// user-measured HRmax beats the formula in every case, and
    /// `effectiveMaxHR` prefers one whenever it exists.
    static func tanaka(age: Int) -> Int {
        let computed = Int((208.0 - 0.7 * Double(age)).rounded())
        return max(floor, min(computed, ceiling))
    }

    /// Below this the input was not a plausible age (130 ≈ age 111).
    static let floor = 130
    /// Above this the input was not a plausible age.
    static let ceiling = 220
    /// The Biometrics field's lower bound; anything under it reads as unset.
    static let minimumUserEntered = 80
    /// Used when there is no birthday to derive an age from.
    static let defaultWithoutBirthday = 180

    /// Completed years between `birthday` and `reference`.
    ///
    /// Takes its calendar explicitly rather than reaching for `Calendar.current`.
    /// Ambient calendar state can shift a date across a day boundary, which at a
    /// birthday flips the age by a year and the resulting HRmax by ~1 bpm —
    /// moving every zone boundary underneath the user.
    static func age(from birthday: Date, to reference: Date, calendar: Calendar) -> Int? {
        calendar.dateComponents([.year], from: birthday, to: reference).year
    }

    /// The whole rule: an explicit value wins; otherwise derive from the
    /// birthday; otherwise a safe floor so downstream zone math never divides
    /// by nil or zero.
    static func effective(
        userEntered: Int?,
        birthday: Date?,
        reference: Date,
        calendar: Calendar
    ) -> Int {
        // Below the field's 80 bpm minimum is a value still being typed (or a
        // slip), not a max heart rate: "18" made every zone and load wrong.
        if let userEntered, userEntered >= minimumUserEntered { return userEntered }
        guard let birthday else { return defaultWithoutBirthday }
        let years = age(from: birthday, to: reference, calendar: calendar) ?? 40
        return tanaka(age: years)
    }
}
