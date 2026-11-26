@testable import Emuqu
import XCTest

/// The routing evaluation: hand-labeled utterances, graded against
/// `CapabilityClassifier.classify(_:)`.
///
/// **Slices.**
///   • A (`real`): voice-style requests, with fillers and run-ons, as people
///     speak to Flo.
///   • B (`adversarial`): short requests (eight words or fewer), most of
///     which need the web, history, speculation or an action.
///   • C (`boundary`): medical refusals, marker words used in statements,
///     other languages the app ships, multi-axis requests and plain lookups.
///
/// **Labels are ground truth**: what the request needs, not what the
/// classifier says. `needsTools` is an action the app takes (email,
/// contacts, directions, the route library, memory); `needsWeb` is
/// information from outside the user's data; `needsHistoricalDepth` is
/// history beyond the recent context block (weeks to months, comparisons
/// with a past season); `needsSpeculation` is a prediction, a what-if or a
/// best guess. A message `MedicalQueryGuard` refuses is answered on the
/// device before routing, so it is labeled with no flags.
///
/// **Splits.** `tuning` is what the classifier's markers, prototypes and
/// embedding settings may be adjusted against: the marker author's own
/// utterances, and 181 by an independent author the markers were then
/// broadened on. `heldOut` is 197 utterances by a second independent author
/// who saw neither the classifier nor any other utterance here. Nothing is
/// adjusted against it: it measures generalization, and the gates below are
/// asserted on it. No utterance in either split may equal or nearly
/// duplicate a classifier prototype (`EvalPrototypeOverlapTests`).
///
/// **Targets and floors.** The targets are capability correctness of 95%
/// on slice A, 85% on slice B and 90% on slice C, and no medical-refusal
/// utterance with a capability flag. Measured on the held-out split (iOS
/// Simulator, exact four-flag labels): 59/79 (75%) on A, 33/48 (69%) on B,
/// 42/70 (60%) on C; the routing tier the flags resolve to is right for
/// 77%, 77% and 69%; medical misroutes 0. The targets are not met. The
/// floors asserted below are the measured scores, so a change that loses
/// ground fails and one that gains can raise them; the targets stay
/// written next to them. Most misses under-detect the web, history or a
/// prediction in phrasing no marker anticipated. A web request routed to
/// Apple is caught at run time instead: Apple's call to `web_search` hands
/// the turn to a consented cloud provider that can search.
enum EvalUtterances {
    enum Slice: String, CaseIterable {
        case real
        case adversarial
        case boundary
    }

    struct Utterance: Equatable {
        let text: String
        let slice: Slice
        let expected: CapabilityClassifier.Requirement
        /// Why the utterance is in the set, when that is not obvious.
        let note: String?
    }

    private static func u(_ text: String, _ slice: Slice, _ expected: CapabilityClassifier.Requirement, _ note: String? = nil) -> Utterance {
        Utterance(text: text, slice: slice, expected: expected, note: note)
    }

    private static func req(
        tools: Bool = false, web: Bool = false, depth: Bool = false, speculation: Bool = false
    ) -> CapabilityClassifier.Requirement {
        CapabilityClassifier.Requirement(needsTools: tools, needsWeb: web, needsHistoricalDepth: depth, needsSpeculation: speculation)
    }

    private static let none = req()
    private static let tools = req(tools: true)
    private static let web = req(web: true)
    private static let depth = req(depth: true)
    private static let guess = req(speculation: true)

    // MARK: - Tuning split

    static let tuning: [Utterance] = authoredTuning + authoredProbe + independentTuning

    /// Written by the author of the held-out split.
    private static let authoredTuning: [Utterance] = [
        // Slice A
        u("can you see the top of the last hill it's noticeable in the workout of the last four or five days", .real, depth),
        u("can i purchase an ai voice to use in my videos", .real, web),
        u("what's your guess for my life expectancy from all this", .real, guess),
        u("tell me about my last workout", .real, none),
        u("what's my recovery score", .real, none),
        u("did i train yesterday", .real, none),
        u("hey flo what's my recovery like today", .real, none),
        u("put this summary in an email to me", .real, tools),
        u("is it hot out there right now", .real, web),
        u("how's my hrv looked over the past eight weeks", .real, depth),
        u("what would my half marathon time be", .real, guess),
        u("uh how did i sleep", .real, none),
        u("steer me back to the parking lot", .real, tools),
        u("okay remember that my long run is on sundays", .real, tools, "memory write"),
        u("how did this spring compare with last autumn for sleep", .real, depth),
        u("hey flo is it gonna snow on my ride tomorrow", .real, web),
        u("what's the wind doing out there", .real, web),
        u("uh how did my sleep look over the past six weeks", .real, depth),
        u("has my resting heart rate come down since last summer", .real, depth),
        u("do you reckon i could break three hours in the marathon", .real, guess),
        u("if i keep running five days a week where will my vo2 max end up", .real, guess),
        u("can you email my training plan to me", .real, tools),
        u("take me back to where i started", .real, tools),
        u("add jane as a contact", .real, tools),
        u("please forget my old address", .real, tools, "memory removal"),
        u("what were my splits on that last run", .real, none),
        u("how hard was yesterday's workout", .real, none),
        u("i'm feeling pretty tired today what should i do", .real, none),
        u("um what's the best trail shoe for mud", .real, web),
        u("are there any races near me this weekend", .real, web),
        // Slice B
        u("email today's report", .adversarial, tools),
        u("weather near me", .adversarial, web),
        u("lead me back", .adversarial, tools),
        u("since january how am i", .adversarial, depth),
        u("predict my next race", .adversarial, guess),
        u("keep this one as a route", .adversarial, tools),
        u("best guess on my finishing time", .adversarial, guess),
        u("show me the way to urgent care", .adversarial, tools),
        u("snow tonight?", .adversarial, web),
        u("pace trend since may", .adversarial, depth),
        u("guess my vo2 max next month", .adversarial, guess),
        u("directions home", .adversarial, tools),
        u("hr today", .adversarial, none),
        u("humidity now", .adversarial, web),
        u("sleep since january", .adversarial, depth),
        u("forecast tonight", .adversarial, web),
        u("temperature now", .adversarial, web),
        u("store hours?", .adversarial, web),
        u("vo2 trend this year", .adversarial, depth),
        u("since last summer", .adversarial, depth),
        u("six week trend", .adversarial, depth),
        u("will i improve", .adversarial, guess),
        u("guess my 5k", .adversarial, guess),
        u("if i taper?", .adversarial, guess),
        u("email me", .adversarial, tools),
        u("navigate home", .adversarial, tools),
        u("save as route", .adversarial, tools),
        u("sleep last night", .adversarial, none),
        u("my zones", .adversarial, none),
        u("cheapest gels", .adversarial, web),
        // Slice C
        u("do i have afib", .boundary, none, "medical refusal"),
        u("is my heart rate dangerous", .boundary, none, "medical refusal"),
        u("i feel chest tightness when running", .boundary, none, "medical refusal"),
        u("search the web for studies on hrv over the last 8 weeks", .boundary, req(web: true, depth: true)),
        u("predict my hrv next month based on the last 12 weeks", .boundary, req(depth: true, speculation: true)),
        u("recovery is hard", .boundary, none),
        u("i did email yesterday", .boundary, none),
        u("the news is good", .boundary, none),
        u("i guess today went fine", .boundary, none),
        u("this month i ran a lot", .boundary, none),
        u("what's my hrv", .boundary, none),
        u("how did i sleep", .boundary, none),
        u("rhr today", .boundary, none),
        u("¿lloverá esta tarde?", .boundary, web, "Spanish"),
        u("wie habe ich geschlafen", .boundary, none, "German"),
        u("search online for hrv studies", .boundary, web),
        u("email my coach my plan for next month", .boundary, tools),
        u("i fell and my knee is bleeding", .boundary, none, "medical refusal"),
        u("my heart is racing and my chest hurts", .boundary, none, "medical refusal"),
        u("i used to google everything", .boundary, none),
        u("last year i ran my first marathon", .boundary, none),
        u("i predicted a bad night and was right", .boundary, none),
        u("¿qué tiempo hace en sevilla?", .boundary, web, "Spanish"),
        u("regnet es morgen", .boundary, web, "German"),
        u("mes progrès sur les trois derniers mois", .boundary, depth, "French"),
        u("previsione del mio recupero", .boundary, guess, "Italian"),
        u("wat voor weer wordt het morgen", .boundary, web, "Dutch"),
        u("明日は雨ですか", .boundary, web, "Japanese"),
        u("내일 날씨 어때", .boundary, web, "Korean"),
        u("明天天气怎么样", .boundary, web, "Chinese"),
        u("какая погода завтра", .boundary, web, "Russian"),
        u("search for my best ride", .boundary, none, "a lookup in the user's own data"),
        u("look up my hrv from last night", .boundary, none, "a lookup in the user's own data"),
        u("email my coach and predict my race time", .boundary, req(tools: true, speculation: true)),
        u("what's the weather and my recovery", .boundary, web)
    ]

    /// Written by an independent author who never saw the classifier, and
    /// graded against it before it was tuned on them. Labels as written,
    /// except where a note says one was corrected.
    private static let independentTuning: [Utterance] = [
        u("um hey Flo what was my HRV this morning", .real, none),
        u("so like how'd I sleep last night, was it okay", .real, none),
        u("hey Flo can you, uh, email my coach the summary of this week's runs", .real, req(tools: true)),
        u("so um is it gonna rain tomorrow morning cause I wanna do my long run, or no wait maybe Saturday", .real, req(web: true)),
        u("hey Flo what's my best 5k ever, like all time", .real, req(depth: true)),
        u("um so if I skip tomorrow's workout will my recovery be better by Thursday", .real, req(speculation: true)),
        u("okay so like give me directions to the trailhead at Bear Creek, the, uh, parking lot one", .real, req(tools: true)),
        u("hey Flo remember that my left knee gets sore on downhills, save that", .real, req(tools: true)),
        u("so what running shoes should I get, I mean for like marathon training, um", .real, req(web: true)),
        u("has my resting heart rate been going down since I started using the app", .real, req(depth: true)),
        u("uh how was yesterday's run, like the pace and stuff", .real, none),
        u("hey Flo, um, will I be ready for the half in three weeks, like honestly", .real, req(speculation: true)),
        u("when's the next big marathon near Denver, I think there's one in the spring", .real, req(web: true)),
        u("so um save this route as Lakeside Loop, yeah that one I just did", .real, req(tools: true)),
        u("hey Flo how many hours of deep sleep did I get last night", .real, none),
        u("compare my HRV this month to like the same time last year, um, I think I was lower", .real, req(depth: true)),
        u("forget the thing I told you about my diet, the keto thing, I stopped", .real, req(tools: true)),
        u("so like what's the weather doing at six, I'm thinking of running before work", .real, req(web: true)),
        u("um hey can you look up whether creatine actually helps recovery online", .real, req(web: true)),
        u("what if I just do easy runs for the next two weeks, like what happens to my HRV", .real, req(speculation: true)),
        u("hey Flo send an email to Marco saying I'm gonna be ten minutes late to the group run, oh wait, make it fifteen", .real, req(tools: true)),
        u("so how's my training load this week, um, am I overdoing it", .real, none),
        u("okay so like what's my average sleep over the last six months", .real, req(depth: true)),
        u("hey um add Sarah's number to my contacts, it's 555 0134", .real, req(tools: true)),
        u("is the Boston marathon registration open yet, like when's the deadline", .real, req(web: true)),
        u("so, uh, my HRV was 48 today is that low for me", .real, none),
        u("uh navigate me to the nearest running track please", .real, req(tools: true)),
        u("best guess, if I keep this up how fast could I run a 10k by spring", .real, req(speculation: true)),
        u("has my sleep gotten worse over the past couple months or is it just me", .real, req(depth: true)),
        u("hey Flo what time does the gym on Main Street close tonight", .real, req(web: true)),
        u("um so what was my heart rate during the intervals yesterday, the average I mean", .real, none),
        u("follow the Riverside route, no wait the, the hilly one, the one I saved last week", .real, req(tools: true)),
        u("hey so like is it true that cold showers help HRV, can you search that", .real, req(web: true)),
        u("um rename my route from Route 12 to Sunday Easy, please", .real, req(tools: true)),
        u("so what do you think my marathon time would be if I train through the winter", .real, req(speculation: true)),
        u("wait how many workouts did I do this week, like total", .real, none),
        u("hey Flo what's the longest run I've ever done in the app", .real, req(depth: true)),
        u("uh what's the air quality like out there right now, should I run outside", .real, req(web: true)),
        u("so like if I drink tonight how bad is it gonna be for my HRV tomorrow", .real, req(speculation: true)),
        u("email my doctor the sleep report from this week, uh, Dr. Patel", .real, req(tools: true)),
        u("hey um remind me, what was my readiness yesterday", .real, none),
        u("has my HRV baseline shifted since I started meditating, that was like back in March", .real, req(depth: true)),
        u("um what's a good heart rate monitor for swimming, like strap or armband", .real, req(web: true)),
        u("hey Flo save a note that I want to try the 80/20 plan after the race", .real, req(tools: true)),
        u("so I ran, uh, 12k this morning and felt rubbish, why do you think", .real, none),
        u("like give me directions home from here, I'm lost on this trail", .real, req(tools: true)),
        u("so when did I last hit a PR on the bike, was it this year", .real, req(depth: true)),
        u("will I be recovered enough for a hard session on Saturday if I sleep badly tonight", .real, req(speculation: true)),
        u("hey Flo what's the news on that new Garmin, the one that came out recently", .real, req(web: true)),
        u("uh how many steps today, did I hit ten thousand", .real, none),
        u("so my pace has been slow lately, um, is it slower than last season", .real, req(depth: true)),
        u("um hey look up the elevation profile of the Chicago marathon course", .real, req(web: true)),
        u("oh and Flo, save that I prefer morning workouts, remember it", .real, req(tools: true)),
        u("so like what's my sleep score for the past three nights", .real, none),
        u("hey, how do I compare to my own average from the whole year", .real, req(depth: true)),
        u("uh can you text, I mean email, my training partner Jess and say the run is moved to seven", .real, req(tools: true)),
        u("um what's going to happen to my fitness if I take two weeks off for vacation", .real, req(speculation: true)),
        u("hey Flo are there any 10k races near me next month", .real, req(web: true)),
        u("so, like, is today a good day to push hard or should I rest", .real, none),
        u("okay um tell me my HRV trend over the last three months", .real, req(depth: true)),
        u("hey Flo what's the best time of year to run a marathon, like weather-wise", .real, req(web: true)),
        u("um do you know how much protein I need to eat, like for endurance athletes", .real, req(web: true)),
        u("so how long was my nap today, I think I slept like forty minutes", .real, none),
        u("uh delete the memory about my shoulder injury, it's healed", .real, req(tools: true)),
        u("predict my recovery for tomorrow, um, given I did a hard ride today", .real, req(speculation: true)),
        u("hey Flo how many times have I run over 20k this year", .real, req(depth: true)),
        u("um look up the contact for Tom at the cycling club, I forgot his number", .real, req(tools: true)),
        u("so what was the sunrise time again, I want to start before it", .real, req(web: true)),
        u("like my body battery thing was low this morning, uh, what does that mean for today's ride", .real, none),
        u("hey so what's in the news about the new Boston qualifying standards, and, um, would I make it with my current fitness", .real, req(web: true, speculation: true)),
        u("Weather this weekend?", .adversarial, req(web: true)),
        u("Email my coach", .adversarial, req(tools: true)),
        u("Best PR ever?", .adversarial, req(depth: true)),
        u("Will I recover by Friday?", .adversarial, req(speculation: true)),
        u("Navigate to the park", .adversarial, req(tools: true)),
        u("Save this route", .adversarial, req(tools: true)),
        u("HRV today?", .adversarial, none),
        u("Last night's sleep?", .adversarial, none),
        u("Best trail shoes 2026?", .adversarial, req(web: true)),
        u("Compare to last year", .adversarial, req(depth: true)),
        u("What if I skip Monday?", .adversarial, req(speculation: true)),
        u("Remember I'm vegetarian", .adversarial, req(tools: true)),
        u("Forget my old goal", .adversarial, req(tools: true)),
        u("Marathons in April near me", .adversarial, req(web: true)),
        u("Trend since January", .adversarial, req(depth: true)),
        u("Search the web for tempo workouts", .adversarial, req(web: true)),
        u("Add Dan to contacts", .adversarial, req(tools: true)),
        u("Predict my 5k time", .adversarial, req(speculation: true)),
        u("Rename that route Hill Repeats", .adversarial, req(tools: true)),
        u("How's my strain today?", .adversarial, none),
        u("Directions to the lake trailhead", .adversarial, req(tools: true)),
        u("Is it raining right now?", .adversarial, req(web: true)),
        u("Lifetime longest ride", .adversarial, req(depth: true)),
        u("Guess my half marathon time", .adversarial, req(speculation: true)),
        u("Latest cycling news", .adversarial, req(web: true)),
        u("Follow the Canal route", .adversarial, req(tools: true)),
        u("Yesterday's workout summary", .adversarial, none),
        u("Am I getting fitter over months?", .adversarial, req(depth: true)),
        u("Opening hours Hillside pool", .adversarial, req(web: true)),
        u("Save this to my notes", .adversarial, req(tools: true)),
        u("Could I PR next month?", .adversarial, req(speculation: true)),
        u("Resting heart rate now?", .adversarial, none),
        u("Sleep average since I started", .adversarial, req(depth: true)),
        u("Recommend a good chest strap", .adversarial, req(web: true)),
        u("Email my sleep report", .adversarial, req(tools: true)),
        u("Who won the Tour yesterday?", .adversarial, req(web: true)),
        u("Should I rest tomorrow?", .adversarial, none),
        u("Hi Flo", .adversarial, none),
        u("Thanks, that helps", .adversarial, none),
        u("Worst sleep ever recorded?", .adversarial, req(depth: true)),
        u("Will tomorrow's run feel good?", .adversarial, req(speculation: true)),
        u("Look up marathon taper plans", .adversarial, req(web: true)),
        u("How did I sleep?", .adversarial, none),
        u("Compare this month with last", .adversarial, req(depth: true)),
        u("Text mum I'll be late", .adversarial, req(tools: true)),
        u("Is it windy outside?", .adversarial, req(web: true)),
        u("Calories burned this morning?", .adversarial, none),
        u("If I train harder, then what?", .adversarial, req(speculation: true)),
        u("Year-over-year HRV change", .adversarial, req(depth: true)),
        u("Where's the nearest bike shop?", .adversarial, req(web: true)),
        u("The weather was great on my run today", .boundary, none),
        u("I emailed my coach yesterday and he said I looked strong", .boundary, none),
        u("Been following a Couch to 5K plan for a few days now", .boundary, none),
        u("My watch navigation was glitchy this morning, anyway, run went fine", .boundary, none),
        u("I read the news about the marathon cutoff and it made me nervous", .boundary, none),
        u("Last year was rough for me, but whatever, just venting", .boundary, none),
        u("Saving up for a new bike, that's why I'm skipping the shop", .boundary, none),
        u("My friend is going to google shoes for me, so never mind", .boundary, none),
        u("I'll probably feel better tomorrow, I always do after a rest day", .boundary, none),
        u("Thanks Flo, the forecast you gave me earlier was spot on", .boundary, none),
        u("I forgot my headphones today so the run was quiet", .boundary, none),
        u("Check the forecast for Sunday's race and tell me whether I'll be ready for it", .boundary, req(web: true, speculation: true)),
        u("Compare my sleep this year with last year and guess where it's heading", .boundary, req(depth: true, speculation: true)),
        u("Look up the Berlin marathon course map and email it to my coach", .boundary, req(tools: true, web: true)),
        u("Find a decent tempo route near the river and save it as Tempo Loop", .boundary, req(tools: true), "relabeled: finding a route near the river is the app's trail discovery, not the web"),
        u("What's my best ever HRV since I started, and what's normal for someone my age according to the internet", .boundary, req(web: true, depth: true)),
        u("Given my last six months of training, what marathon time should I aim for in the fall", .boundary, req(depth: true, speculation: true)),
        u("Search the web for taper tips, then tell me how my own taper is likely to go", .boundary, req(web: true, speculation: true)),
        u("Email my coach my total mileage for the year so far", .boundary, req(tools: true, depth: true)),
        u("Navigate me to the start of the Richmond 10k and tell me what the weather's like there", .boundary, req(tools: true, web: true)),
        u("Remember my goal is sub 3:30 and tell me if that's realistic with two years of data behind me", .boundary, req(tools: true, depth: true, speculation: true)),
        u("Which recovery boots are best right now, and would they help my HRV given how it's gone this year", .boundary, req(web: true, depth: true, speculation: true)),
        u("Compare my races last season with now, and look up the course record at Valencia", .boundary, req(web: true, depth: true)),
        u("Save this route for later, and will I be recovered to run it Sunday?", .boundary, req(tools: true, speculation: true)),
        u("Do I have AFib? My watch flagged an irregular rhythm last night", .boundary, none, "medical"),
        u("Should I stop taking my beta blocker before the race?", .boundary, none, "medical"),
        u("How much ibuprofen can I take before a long run?", .boundary, none, "medical"),
        u("Based on my nights, do I have sleep apnea?", .boundary, none, "medical"),
        u("my heart skips beats sometimes, whats wrong with me", .boundary, none, "medical"),
        u("Can I double my metformin dose on heavy training days?", .boundary, none, "medical"),
        u("My chest feels tight after sprints, is this a heart attack?", .boundary, none, "medical"),
        u("What dose of melatonin should I be taking?", .boundary, none, "medical"),
        u("Is my low HRV from an infection or something worse? Diagnose it", .boundary, none, "medical"),
        u("I think my antidepressants are hurting my HRV, should I come off them?", .boundary, none, "medical"),
        u("Do I have overtraining syndrome or a thyroid problem?", .boundary, none, "medical"),
        u("Can I take Adderall and still train hard? How many mg is safe?", .boundary, none, "medical"),
        u("¿Cómo dormí anoche?", .boundary, none),
        u("Envía un correo a mi entrenador con el resumen de la semana", .boundary, req(tools: true)),
        u("Wie wird das Wetter morgen für meinen Lauf?", .boundary, req(web: true)),
        u("Wie hat sich meine HRV in den letzten sechs Monaten entwickelt?", .boundary, req(depth: true)),
        u("Est-ce que je serai prêt pour le marathon dans un mois ?", .boundary, req(speculation: true)),
        u("Enregistre cet itinéraire sous le nom Boucle du lac", .boundary, req(tools: true)),
        u("Qual è il mio record personale sui 10 km di sempre?", .boundary, req(depth: true)),
        u("Cerca online le migliori scarpe da trail", .boundary, req(web: true)),
        u("Qual foi meu HRV hoje de manhã?", .boundary, none),
        u("E se eu pular o treino amanhã, como fica minha recuperação?", .boundary, req(speculation: true)),
        u("Navigeer me naar het dichtstbijzijnde hardloopparcours", .boundary, req(tools: true)),
        u("Wat was mijn hartslag tijdens de training van gisteren?", .boundary, none),
        u("今週の睡眠の質を教えて", .boundary, none),
        u("去年と比べて私の安静時心拍数はどう変わった？", .boundary, req(depth: true)),
        u("Vad blir vädret på lördag, ska jag springa?", .boundary, req(web: true)),
        u("Gem at jeg har ondt i højre læg, husk det", .boundary, req(tools: true)),
        u("Hvor mange timer sov jeg i natt?", .boundary, none),
        u("Voinko juosta maratonin alle neljän tunnin, arvaa vaan", .boundary, req(speculation: true)),
        u("내 코치에게 이번 주 요약을 이메일로 보내줘", .boundary, req(tools: true)),
        u("帮我查一下上海马拉松的报名时间", .boundary, req(web: true)),
        u("自从我开始使用以来，我的最佳心率变异性是多少？", .boundary, req(depth: true)),
        u("Какая у меня была вариабельность пульса сегодня?", .boundary, none),
        u("Найди в интернете лучшие кроссовки для марафона", .boundary, req(web: true)),
        u("كيف كان نومي الليلة الماضية؟", .boundary, none),
        u("هل سأكون جاهزاً للسباق الأسبوع القادم؟", .boundary, req(speculation: true))
    ]

    // MARK: - Tuning: the marker author's own probe

    /// Written by the author of the markers before the markers, then kept
    /// apart; the markers were later written knowing them, so they tune.
    private static let authoredProbe: [Utterance] = probeA + probeB + probeC

    private static let probeA: [Utterance] = [
        u("hey flo how'd i do last night", .real, none),
        u("um what was my hrv this morning", .real, none),
        u("okay so how recovered am i", .real, none),
        u("how many steps did i get today", .real, none),
        u("what was my resting heart rate", .real, none),
        u("how long did i sleep", .real, none),
        u("was my run this morning hard", .real, none),
        u("quick question am i good to train today", .real, none),
        u("what's my training load looking like", .real, none),
        u("how was my deep sleep", .real, none),
        u("read me my score", .real, none),
        u("what did my heart rate peak at on that ride", .real, none),
        u("can you send that to my coach by email", .real, tools),
        u("um take me home", .real, tools),
        u("get me directions to the trailhead", .real, tools),
        u("add my brother as a contact his number is 555 0199", .real, tools),
        u("save today's loop as a route please", .real, tools),
        u("rename my morning route to river run", .real, tools),
        u("remember that i'm training for a marathon in april", .real, tools, "memory write"),
        u("which routes do i have stored", .real, tools),
        u("is it going to rain this afternoon", .real, web),
        u("hey how many degrees is it outside", .real, web),
        u("what's the forecast for saturday's long run", .real, web, "a weather forecast is web, not speculation"),
        u("is the gym on main street open right now", .real, web),
        u("find me a good pair of trail shoes under a hundred bucks", .real, web),
        u("what's in the news about the boston marathon", .real, web),
        u("how windy is it at the coast today", .real, web),
        u("look up what the air quality is like today", .real, web),
        u("how has my sleep changed over the last couple of months", .real, depth),
        u("um is my hrv better in november than october", .real, depth),
        u("how's my resting heart rate trended since the summer", .real, depth),
        u("am i fitter than i was back in march", .real, depth),
        u("what was my best week of training this year", .real, depth),
        u("show me how my recovery has moved over the past three months", .real, depth),
        u("have my long runs gotten faster since the spring", .real, depth),
        u("what do you think my marathon time would be", .real, guess),
        u("if i take three days off will my hrv bounce back", .real, guess),
        u("where do you reckon my fitness will be in a month", .real, guess),
        u("guess what my recovery score will be tomorrow", .real, guess),
        u("will i be ready for the race in two weeks", .real, guess),
        u("how long until i can run a sub twenty 5k", .real, guess),
        u("what happens to my vo2 max if i add intervals", .real, guess),
        u("based on the last six months what will my resting heart rate be by christmas", .real, req(depth: true, speculation: true)),
        u("email my coach a summary of my last three months of training", .real, req(tools: true, depth: true)),
        u("check the weather and tell me if i should run long tomorrow", .real, web),
        u("hey flo good morning", .real, none),
        u("thanks that's helpful", .real, none),
        u("what zone was i in for most of the ride", .real, none),
        u("how stressed was i yesterday", .real, none),
        u("uh did i hit my sleep goal", .real, none),
        u("how does today compare to yesterday", .real, none, "two days is in the context block"),
        u("what's my hrv compared to my baseline", .real, none),
        u("should i go easy today", .real, none),
        u("why is my score low", .real, none),
        u("what time did i fall asleep", .real, none),
        u("how far did i run this week", .real, none),
        u("what was my average pace", .real, none),
        u("tell me something about my recovery", .real, none),
        u("um how many workouts did i do this week", .real, none),
        u("remind me what my max heart rate is set to", .real, none)
    ]

    private static let probeB: [Utterance] = [
        u("rain later?", .adversarial, web),
        u("weather tomorrow", .adversarial, web),
        u("is it cold out", .adversarial, web),
        u("any storms tonight", .adversarial, web),
        u("sunset time today", .adversarial, web),
        u("uv index now", .adversarial, web),
        u("best running watch", .adversarial, web),
        u("price of the forerunner 965", .adversarial, web),
        u("pool open today?", .adversarial, web),
        u("who won the boston marathon", .adversarial, web),
        u("pollen count", .adversarial, web),
        u("is the park open", .adversarial, web),
        u("headwind on my route?", .adversarial, web),
        u("heat advisory today?", .adversarial, web),
        u("trend since april", .adversarial, depth),
        u("hrv this year", .adversarial, depth),
        u("sleep last quarter", .adversarial, depth),
        u("fitness since christmas", .adversarial, depth),
        u("compare to last spring", .adversarial, depth),
        u("three month trend", .adversarial, depth),
        u("my best month", .adversarial, depth),
        u("rhr over 90 days", .adversarial, depth),
        u("year over year mileage", .adversarial, depth),
        u("race time guess", .adversarial, guess),
        u("will i pr", .adversarial, guess),
        u("forecast my recovery", .adversarial, guess),
        u("what if i rest", .adversarial, guess),
        u("ready by june?", .adversarial, guess),
        u("projected 10k time", .adversarial, guess),
        u("how fit in six weeks", .adversarial, guess),
        u("chances i qualify", .adversarial, guess),
        u("email it", .adversarial, tools),
        u("route home", .adversarial, tools),
        u("directions to work", .adversarial, tools),
        u("save route", .adversarial, tools),
        u("add contact mom", .adversarial, tools),
        u("send my coach this", .adversarial, tools),
        u("back to start", .adversarial, tools),
        u("rename route", .adversarial, tools),
        u("remember my shoe size", .adversarial, tools, "memory write"),
        u("hrv?", .adversarial, none),
        u("sleep score", .adversarial, none),
        u("today's load", .adversarial, none),
        u("weekly summary", .adversarial, none),
        u("last run", .adversarial, none),
        u("recovery", .adversarial, none),
        u("weather and route home", .adversarial, req(tools: true, web: true)),
        u("predict hrv from 3 months", .adversarial, req(depth: true, speculation: true)),
        u("rain on saturday's race?", .adversarial, web),
        u("news on hrv research", .adversarial, web)
    ]

    private static let probeC: [Utterance] = [
        u("i have chest pain after my run", .boundary, none, "medical refusal"),
        u("do you think i have an arrhythmia", .boundary, none, "medical refusal"),
        u("my heart feels irregular is that afib", .boundary, none, "medical refusal"),
        u("i fainted during my workout", .boundary, none, "medical refusal"),
        u("i can't breathe properly after climbing stairs", .boundary, none, "medical refusal"),
        u("is my heart rate of 190 dangerous", .boundary, none, "medical refusal"),
        u("should i be worried about my heart", .boundary, none, "medical refusal"),
        u("i think i'm having a heart attack", .boundary, none, "medical refusal"),
        u("my face is drooping and my arm is numb", .boundary, none, "medical refusal"),
        u("i fell off my bike and hurt my wrist", .boundary, none, "medical refusal"),
        u("i think i broke my ankle on the trail", .boundary, none, "medical refusal"),
        u("predict whether i'll get afib", .boundary, none, "medical refusal with a speculation marker"),
        u("how long will i live with afib", .boundary, none, "medical refusal with a speculation marker"),
        u("search the web for what an irregular heartbeat means", .boundary, none, "medical refusal with a web marker"),
        u("i love running in the rain", .boundary, none),
        u("the weather was perfect for my run yesterday", .boundary, none),
        u("i bought new shoes last week", .boundary, none),
        u("my coach emailed me a plan", .boundary, none),
        u("i guess i slept okay", .boundary, none),
        u("what if i told you i slept ten hours", .boundary, none, "conversational what-if"),
        u("i ran past the news stand", .boundary, none),
        u("my route was windy today", .boundary, none),
        u("search for my last run", .boundary, none, "a lookup in the user's own data"),
        u("look up my sleep from tuesday", .boundary, none, "a lookup in the user's own data"),
        u("compared to a normal day how was today", .boundary, none),
        u("this month has been busy", .boundary, none),
        u("since i started using the app i sleep better", .boundary, none),
        u("what's my hrv baseline", .boundary, none),
        u("how many hours did i sleep last night", .boundary, none),
        u("what did i do yesterday", .boundary, none),
        u("¿qué tiempo hará mañana en madrid?", .boundary, web, "Spanish"),
        u("¿cuál fue mi variabilidad cardíaca anoche?", .boundary, none, "Spanish"),
        u("wie wird das wetter heute abend", .boundary, web, "German"),
        u("wie hat sich mein ruhepuls in den letzten drei monaten entwickelt", .boundary, depth, "German"),
        u("quel temps fait-il à lyon aujourd'hui", .boundary, web, "French"),
        u("combien de temps ai-je dormi cette nuit", .boundary, none, "French"),
        u("prevedi il mio tempo nella maratona", .boundary, guess, "Italian"),
        u("como foi meu sono ontem", .boundary, none, "Portuguese"),
        u("hoe was mijn herstel vandaag", .boundary, none, "Dutch"),
        u("今日の天気は？", .boundary, web, "Japanese"),
        u("hur sov jag i natt", .boundary, none, "Swedish"),
        u("search online for marathon plans that fit my last two months of training", .boundary, req(web: true, depth: true)),
        u("if the forecast says rain should i move my long run", .boundary, web),
        u("email me a prediction of my race time", .boundary, req(tools: true, speculation: true)),
        u("look at my last 8 months and guess my peak week next year", .boundary, req(depth: true, speculation: true)),
        u("what's the weather and how did i sleep", .boundary, web),
        u("give me a recap of this week", .boundary, none),
        u("how's my strain today", .boundary, none),
        u("did my hrv go up or down since yesterday", .boundary, none),
        u("what's my readiness", .boundary, none),
        u("explain my recovery score", .boundary, none),
        u("is today a rest day", .boundary, none),
        u("walk me to the closest drinking fountain", .boundary, tools),
        u("forget what i told you about my knee", .boundary, tools, "memory removal"),
        u("delete the contact for sam", .boundary, tools),
        u("start directions back to my car", .boundary, tools),
        u("write an email to my physio with my sleep data", .boundary, tools),
        u("how do i compare with other runners my age", .boundary, web, "population norms are outside the user's data"),
        u("what does the latest science say about cold plunges", .boundary, web),
        u("year to date how many miles have i run", .boundary, depth)
    ]

    // MARK: - Held-out split

    /// Written by an author who saw neither the classifier, its markers and
    /// prototypes, nor any other utterance here, from the label definitions
    /// alone. Nothing in the classifier is adjusted against it.
    static let heldOut: [Utterance] = heldOutA + heldOutB + heldOutC

    private static let heldOutA: [Utterance] = [
        u("hey flo can you uh send an email to my coach with my uh my sleep from last night", .real, tools),
        u("is it gonna rain on my run tomorrow morning", .real, web),
        u("how's my resting heart rate been trending since like august", .real, depth),
        u("so if i skip the long run this weekend will my recovery be better on monday", .real, guess),
        u("save this route as uh river loop", .real, tools),
        u("remember that i'm um no wait remember that my left knee's been sore since the trail run", .real, tools),
        u("what's a good uh electrolyte drink for long rides", .real, web),
        u("how did i sleep last night", .real, none),
        u("compare my hrv this month to the same time last year", .real, depth),
        u("navigate me to the uh the trailhead at bear creek", .real, tools),
        u("what's the latest news on the boston marathon qualifying times", .real, web),
        u("do you think i'll be recovered enough for the race on saturday", .real, guess),
        u("add sarah as a contact her number is five five five one two three four", .real, tools),
        u("what's my longest run ever", .real, depth),
        u("how much protein should someone like my weight eat for muscle recovery", .real, web),
        u("rename the uh the morning route to coffee loop", .real, tools),
        u("uh so my strain today was what", .real, none),
        u("my hr wee readiness uh what's my readiness score", .real, none, "misrecognition"),
        u("i wonder would i sleep better if i stopped drinking coffee after noon", .real, guess),
        u("find me a pool near here that's open right now", .real, web),
        u("how many workouts did i do this week", .real, none),
        u("forget what i told you about my um my half marathon goal", .real, tools),
        u("has my vo two max gone up over the last six months", .real, depth),
        u("what's the uv index today", .real, web),
        u("um start navigation on the uh lakeside route from my library", .real, tools),
        u("if i keep training like this where's my hrv gonna be by christmas", .real, guess),
        u("what did my heart rate do during yesterday's ride", .real, none),
        u("are there any uh park runs this saturday near me", .real, web),
        u("email my wife that i'll be back from the run in like forty minutes", .real, tools),
        u("how does this year's training volume stack up against last year", .real, depth),
        u("is zone two training actually backed by research or is that just hype", .real, web),
        u("what would happen to my score if i went to bed an hour earlier tonight", .real, guess),
        u("note that uh i felt really heavy legs on the uh the hill repeats today", .real, tools),
        u("what was my average sleep over the summer", .real, depth),
        u("uh how hot is it outside right now", .real, web),
        u("my uh my hrv dropped today why", .real, none),
        u("look up uh mark's email in my contacts", .real, tools),
        u("how many miles do running shoes usually last before they wear out", .real, web),
        u("give me directions home", .real, tools),
        u("since i started using the app has my resting heart rate come down", .real, depth),
        u("what's my recovery gonna look like tomorrow after this beer you reckon", .real, guess),
        u("what's the best uh heart rate strap for swimming", .real, web),
        u("how long was my walk today", .real, none),
        u("uh tell me what my best five k time was last spring", .real, depth),
        u("add the uh the hill route i just did to my saved routes", .real, tools),
        u("is the gym on fifth street open on thanksgiving", .real, web),
        u("say i hold this pace for the whole marathon what kind of finish time are we talking", .real, guess),
        u("did i hit my sleep goal this week", .real, none),
        u("save to memory that my max heart rate is one eighty seven", .real, tools),
        u("what's the elevation of uh mount whitney", .real, web),
        u("show me how my deep sleep's changed over the past three months", .real, depth),
        u("could i handle a double workout tomorrow you think", .real, guess),
        u("send dave the route from this morning by email", .real, tools),
        u("um what's my heart rate variability right now", .real, none),
        u("what does the science say about sauna after workouts", .real, web),
        u("uh how many miles have i logged total like all time", .real, depth),
        u("take me to the nearest uh bike shop", .real, req(tools: true, web: true)),
        u("if the weather holds would i be ready for a hundred k ride next week", .real, guess),
        u("what did i eat no wait what was my calorie burn yesterday", .real, none),
        u("was october my best month for recovery", .real, depth),
        u("whats the forecast for the weekend in denver", .real, web),
        u("follow the uh the canal route", .real, tools),
        u("uh hey flo good morning", .real, none),
        u("how many calories are in a uh banana", .real, web),
        u("what's the trend on my hrv since my injury back in july", .real, depth),
        u("picture me cutting my mileage in half what happens to my fitness", .real, guess),
        u("write down that my new shoes are the uh the pegasus forty one", .real, tools),
        u("was my sleep score better tuesday or wednesday", .real, none),
        u("is there a uh a half marathon in portland in march", .real, web),
        u("my training load from last season versus now", .real, depth),
        u("uh what do you figure my hrv'll be after the flight to tokyo", .real, guess),
        u("delete the note about my uh my knee", .real, tools),
        u("uh how did my legs uh how did my recovery look after saturday's ride", .real, none),
        u("who won the tour de france this year", .real, web),
        u("flo whats my respiratory rate been the last couple nights", .real, none),
        u("uh e-mail the uh the weekly summary to jen at her work address", .real, tools),
        u("had i taken a rest day yesterday would my readiness be higher", .real, guess),
        u("what's my all time highest hrv reading", .real, depth),
        u("can you uh find a coffee shop near the start of my route that opens early", .real, web)
    ]

    private static let heldOutB: [Utterance] = [
        u("hrv trend this year", .adversarial, depth),
        u("email coach my sleep", .adversarial, tools),
        u("will I PR saturday?", .adversarial, guess),
        u("save route as Hilltop", .adversarial, tools),
        u("today's readiness", .adversarial, none),
        u("best trail shoes 2026", .adversarial, web),
        u("resting HR since January", .adversarial, depth),
        u("directions to Golden Gate Park", .adversarial, tools),
        u("forget my old max HR", .adversarial, tools),
        u("does creatine help runners?", .adversarial, web),
        u("last night's sleep", .adversarial, none),
        u("fastest 10k ever", .adversarial, depth),
        u("recovery tomorrow if I drink?", .adversarial, guess),
        u("add Tom to contacts", .adversarial, tools),
        u("races near me in April", .adversarial, web),
        u("sleep vs last winter", .adversarial, depth),
        u("predict my marathon time", .adversarial, guess),
        u("rename route to Dogwalk", .adversarial, tools),
        u("steps this week", .adversarial, none),
        u("monthly mileage 2025", .adversarial, depth),
        u("air quality now", .adversarial, web),
        u("remember: race is May 3", .adversarial, tools),
        u("can I manage 20 miles Sunday?", .adversarial, guess),
        u("magnesium for sleep", .adversarial, web),
        u("lowest HRV all year", .adversarial, depth),
        u("navigate to work", .adversarial, tools),
        u("thanks Flo", .adversarial, none),
        u("sunset time", .adversarial, web),
        u("VO2 max since I started", .adversarial, depth),
        u("would a 1-week taper work for me?", .adversarial, guess),
        u("Mia's email address", .adversarial, tools),
        u("gyms open now", .adversarial, web),
        u("yearly HRV average", .adversarial, depth),
        u("follow Riverside route", .adversarial, tools),
        u("how was my workout", .adversarial, none),
        u("Strava news", .adversarial, web),
        u("ready for an Ironman next year?", .adversarial, guess),
        u("longest sleep streak", .adversarial, depth),
        u("note: new insoles", .adversarial, tools),
        u("carbs before a race?", .adversarial, web),
        u("and with no caffeine?", .adversarial, guess),
        u("Sept vs Oct recovery", .adversarial, depth),
        u("send this to Anna", .adversarial, tools),
        u("HRV now", .adversarial, none),
        u("search lactate threshold", .adversarial, web),
        u("best month ever", .adversarial, depth),
        u("deload week, likely effect?", .adversarial, guess),
        u("wind at the coast", .adversarial, web)
    ]

    private static let heldOutC: [Utterance] = [
        u("Ran in the rain today, totally soaked but it felt great.", .boundary, none, "statement"),
        u("My coach emailed me the new plan this morning.", .boundary, none, "statement"),
        u("I saved a ton of routes in another app years ago, funny to think about now.", .boundary, none, "statement"),
        u("The weather's been awful all week.", .boundary, none, "statement"),
        u("Last year was a rough one for my training, honestly.", .boundary, none, "statement"),
        u("My friend keeps predicting I'll get injured before the race, lol.", .boundary, none, "statement"),
        u("Saw some news about HRV and alcohol yesterday.", .boundary, none, "statement"),
        u("Since I started running I've met so many people.", .boundary, none, "statement"),
        u("Just got back from the marathon expo, so many shoes everywhere.", .boundary, none, "statement"),
        u("My sister lives right by the trailhead we always use.", .boundary, none, "statement"),
        u("Tomorrow's going to be a huge day at work.", .boundary, none, "statement"),
        u("I used to write everything down in a notebook before I had this app.", .boundary, none, "statement"),
        u("Ok, the directions you gave me yesterday were spot on.", .boundary, none, "statement"),
        u("Haha imagine me actually running an ultra one day.", .boundary, none, "statement"),
        u("Check the forecast and tell me if my recovery will be good enough for a long ride Saturday", .boundary, req(web: true, speculation: true), "multi"),
        u("Email my coach a summary of how my HRV has changed since March", .boundary, req(tools: true, depth: true), "multi"),
        u("Going off my last six months, what marathon time could I pull off this spring?", .boundary, req(depth: true, speculation: true), "multi"),
        u("Find a 10k in my area next month and save it to my notes", .boundary, req(tools: true, web: true), "multi"),
        u("Compare my sleep this autumn with last autumn and take a stab at how this winter goes", .boundary, req(depth: true, speculation: true), "multi"),
        u("Navigate me to the closest running track that's open right now", .boundary, req(tools: true, web: true), "multi"),
        u("Look up what the research says about HRV at altitude and tell me how my Colorado trip will hit me", .boundary, req(web: true, speculation: true), "multi"),
        u("Send Jake an email with my all-time best 5k and half marathon times", .boundary, req(tools: true, depth: true), "multi"),
        u("With a year of my data and tomorrow's heat wave, am I in for a bad run?", .boundary, req(web: true, depth: true, speculation: true), "multi"),
        u("Remember that my HRV baseline last year was around 55, and tell me where it's heading", .boundary, req(tools: true, depth: true, speculation: true), "multi"),
        u("Is there a bike shop anywhere near the Riverside route? Add it to that route's notes", .boundary, req(tools: true, web: true), "multi"),
        u("How did my recovery hold up in last year's heat, and is this summer looking worse given the forecast?", .boundary, req(web: true, depth: true, speculation: true), "multi"),
        u("What's a solid recovery meal? Save it to my memory", .boundary, req(tools: true, web: true), "multi"),
        u("Email my training partner the long-term trend in my resting heart rate plus your read on my race day readiness", .boundary, req(tools: true, depth: true, speculation: true), "multi"),
        u("Would I recover faster following the latest sleep research instead of my current routine?", .boundary, req(web: true, speculation: true), "multi"),
        u("Directions to the race start, and how's the weather looking there", .boundary, req(tools: true, web: true), "multi"),
        u("Have I ever run this fast in the cold before, and what's the temperature tomorrow", .boundary, req(web: true, depth: true), "multi"),
        u("Do I have atrial fibrillation? My HRV is all over the place.", .boundary, none, "medical"),
        u("How many mg of melatonin should I take?", .boundary, none, "medical"),
        u("Can I stop my beta blockers now that my resting heart rate is low?", .boundary, none, "medical"),
        u("My chest gets tight on hills, is that angina?", .boundary, none, "medical"),
        u("Should I double my metformin on long ride days?", .boundary, none, "medical"),
        u("Is my low HRV a sign of thyroid disease?", .boundary, none, "medical"),
        u("Can I take ibuprofen with my blood pressure meds before a race?", .boundary, none, "medical"),
        u("Night sweats and a high resting HR, could it be an infection or something worse?", .boundary, none, "medical"),
        u("Is it safe to come off my antidepressants since my sleep is better?", .boundary, none, "medical"),
        u("¿Cuántos miligramos de ibuprofeno puedo tomar después de correr?", .boundary, none, "medical"),
        u("Habe ich Herzrhythmusstörungen, wenn mein Puls nachts so springt?", .boundary, none, "medical"),
        u("Est-ce que je peux arrêter mon traitement pour la tension si mon cœur va mieux ?", .boundary, none, "medical"),
        u("¿Qué tal dormí anoche?", .boundary, none, "es"),
        u("Mándale un correo a mi entrenador con mi resumen de la semana", .boundary, tools, "es"),
        u("Wie hat sich meine HRV seit dem Frühling entwickelt?", .boundary, depth, "de"),
        u("Wird es morgen früh regnen?", .boundary, web, "de"),
        u("Si je cours demain, est-ce que je serai récupéré pour samedi ?", .boundary, guess, "fr"),
        u("Enregistre ce parcours sous le nom « boucle du canal »", .boundary, tools, "fr"),
        u("Qual è stata la mia corsa più lunga di sempre?", .boundary, depth, "it"),
        u("Ci sono gare podistiche a Milano a dicembre?", .boundary, web, "it"),
        u("Como está minha recuperação hoje?", .boundary, none, "pt"),
        u("Me leva até o parque mais próximo", .boundary, req(tools: true, web: true), "pt"),
        u("Hoe was mijn slaapscore vergeleken met vorig jaar?", .boundary, depth, "nl"),
        u("Onthoud dat mijn rustpols ongeveer 48 is", .boundary, tools, "nl"),
        u("明日の天気はどうですか", .boundary, web, "ja"),
        u("このまま続けたら来月のHRVはどうなると思う？", .boundary, guess, "ja"),
        u("Hur har min vilopuls förändrats det senaste halvåret?", .boundary, depth, "sv"),
        u("Send en mail til Mette med min træning fra i dag", .boundary, tools, "da"),
        u("Hva er de beste løpeskoene for vinterløping?", .boundary, web, "no"),
        u("Miten nukuin viime yönä?", .boundary, none, "fi"),
        u("Hvernig verður veðrið á morgun í Reykjavík?", .boundary, web, "is"),
        u("작년이랑 비교해서 내 수면이 좋아졌어?", .boundary, depth, "ko"),
        u("내일 마라톤 뛰면 기록이 어떻게 나올까?", .boundary, guess, "ko"),
        u("帮我把今天的路线保存为湖边环线", .boundary, tools, "zh"),
        u("根据我过去半年的数据，你觉得我下个月能跑进三小时吗？", .boundary, req(depth: true, speculation: true), "zh"),
        u("Какая погода будет в выходные и успею ли я восстановиться к гонке?", .boundary, req(web: true, speculation: true), "ru"),
        u("كيف كان معدل ضربات قلبي أثناء تمرين اليوم؟", .boundary, none, "ar"),
        u("ابحث عن صالة رياضية قريبة مفتوحة الآن", .boundary, web, "ar"),
        u("Добавь Ивана в контакты", .boundary, tools, "ru")
    ]

    static let all: [Utterance] = tuning + heldOut
}

/// `RouterEvalTests` grades the classifier against the labels, per split and
/// slice, and asserts the gates on the held-out split.
@MainActor
final class RouterEvalTests: XCTestCase {
    /// Accuracy per slice of `utterances`, printing every miss so a
    /// regression is diagnosable from the CI log.
    private func accuracy(of utterances: [EvalUtterances.Utterance], label: String) -> [EvalUtterances.Slice: Double] {
        var result: [EvalUtterances.Slice: Double] = [:]
        for slice in EvalUtterances.Slice.allCases {
            let items = utterances.filter { $0.slice == slice }
            let misses = items.filter { CapabilityClassifier.shared.classify($0.text) != $0.expected }
            for miss in misses {
                let actual = CapabilityClassifier.shared.classify(miss.text)
                print("[Eval] \(label) \(slice.rawValue) miss: \"\(miss.text)\" expected \(miss.expected.debugSummary), got \(actual.debugSummary)")
            }
            result[slice] = items.isEmpty ? 0 : Double(items.count - misses.count) / Double(items.count)
            print("[Eval] \(label) \(slice.rawValue): \(items.count - misses.count)/\(items.count)")
        }
        return result
    }

    func testHeldOutCapabilityCorrectnessHoldsItsFloors() {
        _ = accuracy(of: EvalUtterances.tuning, label: "tuning")
        let heldOut = accuracy(of: EvalUtterances.heldOut, label: "held-out")
        XCTAssertGreaterThanOrEqual(heldOut[.real] ?? 0, 59.0 / 79, "Slice A (voice-style) held-out floor 75%; target 95%")
        XCTAssertGreaterThanOrEqual(heldOut[.adversarial] ?? 0, 33.0 / 48, "Slice B (short) held-out floor 69%; target 85%")
        XCTAssertGreaterThanOrEqual(heldOut[.boundary] ?? 0, 42.0 / 70, "Slice C (boundary) held-out floor 60%; target 90%")
    }

    /// The embedding settings are the ones that grade the tuning split
    /// best; the held-out split plays no part in choosing them. A gate
    /// drops a marked axis whose cosine falls short of it; a raise lets an
    /// unmarked axis fire on its cosine alone.
    func testTheEmbeddingIsCalibratedOnTheTuningSplit() {
        let gates: [Double] = [0, 0.3, 0.4, 0.5]
        let raises: [Double] = [0, 0.6, 0.7, 0.8, 0.9]
        let settings: [(gate: Double, raise: Double)] = gates.flatMap { gate in raises.map { (gate: gate, raise: $0) } }
        let correct = { (gate: Double, raise: Double) in
            EvalUtterances.tuning.filter {
                CapabilityClassifier.shared.classify($0.text, embeddingGate: gate, embeddingRaise: raise) == $0.expected
            }.count
        }
        let scores = settings.map { (setting: $0, correct: correct($0.gate, $0.raise)) }
        for score in scores { print("[Eval] tuning gate \(score.setting.gate) raise \(score.setting.raise): \(score.correct)/\(EvalUtterances.tuning.count)") }
        let best = scores.map { $0.correct }.max() ?? 0
        XCTAssertEqual(correct(CapabilityClassifier.embeddingGate, 0), best, "the shipped setting is not the tuning split's best")
    }

    /// **0% misroute on medical-refusal utterances**, checked on its own
    /// rather than inside a slice average: the guard refuses each one, and
    /// the classifier raises no flag that would send it to a cloud tier.
    func testZeroMisrouteOnMedicalRefusalUtterances() {
        let medical = EvalUtterances.all.filter { MedicalQueryGuard.classify($0.text) != nil }
        XCTAssertGreaterThanOrEqual(medical.count, 15, "the gate is meaningless without medical-refusal utterances")
        for utterance in medical {
            XCTAssertNotEqual(MedicalQueryGuard.evaluate(utterance.text), .proceed, utterance.text)
            XCTAssertEqual(CapabilityClassifier.shared.classify(utterance.text), .none, "medical utterance misrouted: \(utterance.text)")
        }
    }

    /// A fixture that silently empties is a gate that silently stops testing.
    func testCatalogIsPopulated() {
        XCTAssertGreaterThanOrEqual(EvalUtterances.heldOut.count, 150)
        for slice in EvalUtterances.Slice.allCases {
            XCTAssertGreaterThanOrEqual(EvalUtterances.heldOut.filter { $0.slice == slice }.count, 40, slice.rawValue)
            XCTAssertGreaterThanOrEqual(EvalUtterances.tuning.filter { $0.slice == slice }.count, 12, slice.rawValue)
        }
        XCTAssertTrue(
            Set(EvalUtterances.tuning.map(\.text)).isDisjoint(with: EvalUtterances.heldOut.map(\.text)),
            "a held-out utterance is also in the tuning split"
        )
    }
}

/// No eval utterance and no `CapabilityClassifierTests` phrase may be a
/// classifier prototype or a near copy of one: a test on a prototype shows
/// the classifier recognizes its own examples, not that it generalizes.
final class EvalPrototypeOverlapTests: XCTestCase {
    /// Lowercased words, punctuation dropped.
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// Equal once normalized, or sharing at least half their distinct words.
    static func nearlyDuplicates(_ a: String, _ b: String) -> Bool {
        let (x, y) = (words(a), words(b))
        if x == y { return true }
        let (setX, setY) = (Set(x), Set(y))
        let union = setX.union(setY).count
        return union > 0 && Double(setX.intersection(setY).count) / Double(union) >= 0.5
    }

    private static var prototypePhrases: [String] {
        CapabilityClassifier.prototypes.values.flatMap { $0 }
    }

    /// The strings `CapabilityClassifierTests` classifies, read from its source.
    private static func classifierTestPhrases() throws -> [String] {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("CapabilityClassifierTests.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"classify\("((?:[^"\\]|\\.)*)"\)"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func testNoEvalUtteranceCopiesAPrototype() {
        for utterance in EvalUtterances.all {
            for prototype in Self.prototypePhrases where Self.nearlyDuplicates(utterance.text, prototype) {
                XCTFail("\"\(utterance.text)\" copies the prototype \"\(prototype)\"")
            }
        }
    }

    func testNoClassifierTestPhraseCopiesAPrototype() throws {
        let phrases = try Self.classifierTestPhrases()
        XCTAssertGreaterThanOrEqual(phrases.count, 15, "the phrases were not found in CapabilityClassifierTests.swift")
        for phrase in phrases {
            for prototype in Self.prototypePhrases where Self.nearlyDuplicates(phrase, prototype) {
                XCTFail("\"\(phrase)\" copies the prototype \"\(prototype)\"")
            }
        }
    }

    /// The overlap check catches what it is meant to.
    func testTheOverlapCheckCatchesCopiesAndPassesParaphrases() {
        XCTAssertTrue(Self.nearlyDuplicates("what's the weather right now", "What's the weather right now?"))
        XCTAssertTrue(Self.nearlyDuplicates("lead me back to where I parked", "Lead me back to where I parked the car."))
        XCTAssertFalse(Self.nearlyDuplicates("is it going to rain this afternoon", "What's the weather right now?"))
    }
}
