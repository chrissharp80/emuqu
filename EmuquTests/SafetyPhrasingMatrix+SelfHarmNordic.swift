@testable import Emuqu
import Foundation

// Danish, Norwegian Bokmål, Swedish, Finnish and Icelandic. The declared
// intent is a plain future ("jeg skal", "jag ska", "ég ætla að") or a present
// used for the future ("tapan itseni"), not a wish, and the same verbs carry
// the climbing idiom ("bakken tar livet av meg", "þessi brekka er að drepa
// mig") and "ta livet med ro" (take it easy).

extension SafetyPhrasingMatrix {
    static let selfHarmNordic: [Row<SelfHarmForm>] = [danish, norwegian, swedish, finnish, icelandic]

    private static let danish = Row<SelfHarmForm>(language: "da", cells: [
        .passiveWish: ["jeg ville ønske, jeg var død", "jeg vil bare ikke vågne op igen", "jeg ville hellere være død"],
        .activeWish: ["jeg vil slå mig selv ihjel", "jeg vil dø", "jeg vil tage mit eget liv"],
        .declaredIntent: ["jeg slår mig selv ihjel", "jeg vil begå selvmord", "jeg kommer til at slå mig selv ihjel", "jeg tager mit eget liv"],
        .planWithMethod: ["jeg vil hænge mig", "jeg springer ud fra broen", "jeg tager alle mine piller på én gang"],
        .planWithTime: ["i nat slår jeg mig selv ihjel", "i morgen tager jeg mit eget liv"],
        .preparatoryAct: ["jeg har skrevet et afskedsbrev", "jeg har samlet piller sammen", "jeg sparer piller op"],
        .pastAttempt: ["jeg har forsøgt at slå mig selv ihjel", "jeg har taget for mange piller", "jeg prøvede at begå selvmord"],
        .hopelessness: ["alle ville have det bedre uden mig", "jeg er en byrde for alle", "mit liv har ingen mening"],
        .notWantingToBeHere: ["jeg vil ikke være her mere", "jeg vil ikke være her længere"],
        .selfInjury: ["jeg skærer i mig selv", "jeg vil skade mig selv", "jeg skader mig selv med vilje"],
        .methodQuestion: ["hvad er en dødelig dosis paracetamol", "hvor mange sovepiller skal der til for at dø", "hvor mange piller er dødeligt"]
    ], negatives: [
        "den bakke slår mig ihjel", "jeg er ved at dø efter den tur", "jeg tager mine piller hver morgen",
        "jeg har slået mig på knæet", "jeg vil hænge mig på gruppen i morgen"
    ])

    private static let norwegian = Row<SelfHarmForm>(language: "nb", cells: [
        .passiveWish: ["jeg skulle ønske jeg var død", "jeg vil bare ikke våkne igjen", "jeg vil heller være død"],
        .activeWish: ["jeg vil ta livet av meg", "jeg vil dø", "jeg har lyst til å dø"],
        .declaredIntent: ["jeg skal ta livet av meg", "jeg kommer til å ta livet mitt", "jeg tar livet av meg", "jeg kommer til å ta livet av meg"],
        .planWithMethod: ["jeg skal henge meg", "jeg hopper fra brua", "jeg skal ta alle pillene mine på en gang"],
        .planWithTime: ["i natt tar jeg livet av meg", "i morgen skal jeg ta livet mitt"],
        .preparatoryAct: ["jeg har skrevet et avskjedsbrev", "jeg har samlet opp piller", "jeg sparer på pillene for å ta livet av meg"],
        .pastAttempt: ["jeg har prøvd å ta livet av meg", "jeg tok for mange piller", "jeg forsøkte selvmord"],
        .hopelessness: ["alle hadde hatt det bedre uten meg", "jeg er en byrde for alle", "livet mitt har ingen mening"],
        .notWantingToBeHere: ["jeg vil ikke være her mer", "jeg vil ikke være her lenger"],
        .selfInjury: ["jeg kutter meg selv", "jeg vil skade meg selv", "jeg skader meg selv med vilje"],
        .methodQuestion: ["hva er en dødelig dose paracet", "hvor mange sovetabletter skal til for å dø", "hvor mange piller er dødelig"]
    ], negatives: [
        "den bakken tar livet av meg", "jeg holder på å dø etter økta", "jeg tar pillene mine hver morgen",
        "kan jeg henge meg på økta i morgen?", "jeg skal ta livet med ro i dag", "jeg slo meg på kneet"
    ])

    private static let swedish = Row<SelfHarmForm>(language: "sv", cells: [
        .passiveWish: ["jag önskar att jag var död", "jag vill bara somna och aldrig vakna", "jag vill hellre vara död"],
        .activeWish: ["jag vill ta livet av mig", "jag vill dö", "jag vill begå självmord"],
        .declaredIntent: ["jag ska ta livet av mig", "jag kommer att ta livet av mig", "jag tar livet av mig"],
        .planWithMethod: ["jag ska hänga mig", "jag hoppar från bron", "jag ska ta alla mina tabletter på en gång"],
        .planWithTime: ["i natt tar jag livet av mig", "i morgon ska jag ta livet av mig"],
        .preparatoryAct: ["jag har skrivit ett avskedsbrev", "jag har samlat på mig tabletter", "jag sparar tabletter för att ta livet av mig"],
        .pastAttempt: ["jag har försökt ta livet av mig", "jag tog för många tabletter", "jag gjorde ett självmordsförsök"],
        .hopelessness: ["alla skulle ha det bättre utan mig", "jag är en börda för alla", "mitt liv har ingen mening"],
        .notWantingToBeHere: ["jag vill inte vara här längre", "jag vill inte finnas längre"],
        .selfInjury: ["jag skär mig själv", "jag vill skada mig själv", "jag skadar mig själv med flit"],
        .methodQuestion: ["vad är en dödlig dos paracetamol", "hur många sömntabletter krävs för att dö", "hur många tabletter är dödligt"]
    ], negatives: [
        "backen tar livet av mig", "jag dör efter det passet", "jag vill hänga med på passet",
        "jag tar mina tabletter varje morgon", "jag skadade knät på löpturen"
    ])

    private static let finnish = Row<SelfHarmForm>(language: "fi", cells: [
        .passiveWish: ["toivon että olisin kuollut", "haluaisin nukahtaa enkä herätä enää", "olisin mieluummin kuollut"],
        .activeWish: ["haluan tappaa itseni", "haluan kuolla", "haluan tehdä itsemurhan"],
        .declaredIntent: ["tapan itseni", "aion tappaa itseni", "minä tapan itseni", "teen itsemurhan"],
        .planWithMethod: ["aion hirttää itseni", "hyppään sillalta", "aion ottaa kaikki lääkkeeni kerralla"],
        .planWithTime: ["tänä yönä tapan itseni", "huomenna lopetan elämäni"],
        .preparatoryAct: ["kirjoitin jäähyväiskirjeen", "olen kerännyt lääkkeitä", "säästän pillereitä"],
        .pastAttempt: ["yritin tappaa itseni", "otin liikaa lääkkeitä", "yritin itsemurhaa"],
        .hopelessness: ["kaikilla olisi parempi ilman minua", "olen taakka kaikille", "elämälläni ei ole mitään merkitystä"],
        .notWantingToBeHere: ["en halua olla täällä enää", "en halua enää olla olemassa"],
        .selfInjury: ["viillän itseäni", "haluan satuttaa itseäni", "satutan itseäni tahallani"],
        .methodQuestion: ["mikä on tappava annos parasetamolia", "kuinka monta unilääkettä tarvitaan kuolemaan", "montako pilleriä tappaa ihmisen"]
    ], negatives: [
        "tämä mäki tappaa minut", "kuolen tämän lenkin jälkeen", "otan lääkkeeni joka aamu", "satutin polveni lenkillä"
    ])

    private static let icelandic = Row<SelfHarmForm>(language: "is", cells: [
        .passiveWish: ["ég vildi að ég væri dauður", "ég vil bara sofna og aldrei vakna aftur", "ég vildi frekar vera dáin"],
        .activeWish: ["ég vil drepa mig", "ég vil deyja", "mig langar að taka mitt eigið líf"],
        .declaredIntent: ["ég ætla að drepa mig", "ég mun drepa mig", "ég ætla að fremja sjálfsvíg"],
        .planWithMethod: ["ég ætla að hengja mig", "ég ætla að stökkva fram af brúnni", "ég ætla að taka allar töflurnar mínar í einu"],
        .planWithTime: ["í nótt ætla ég að drepa mig", "á morgun ætla ég að binda enda á líf mitt"],
        .preparatoryAct: ["ég hef skrifað kveðjubréf", "ég hef safnað töflum", "ég er búin að safna pillum"],
        .pastAttempt: ["ég reyndi að drepa mig", "ég tók of margar töflur", "ég reyndi sjálfsvíg"],
        .hopelessness: ["allir væru betur settir án mín", "ég er byrði á öllum", "lífið mitt hefur engan tilgang"],
        .notWantingToBeHere: ["ég vil ekki vera hérna lengur", "ég vil ekki vera til lengur"],
        .selfInjury: ["ég sker mig viljandi", "ég vil skaða mig", "ég meiði mig viljandi"],
        .methodQuestion: ["hver er banvænn skammtur af parasetamóli", "hversu margar svefntöflur þarf til að deyja", "hvað þarf margar töflur til að deyja"]
    ], negatives: [
        "þessi brekka er að drepa mig", "þetta mun drepa mig", "ég er að drepast eftir æfinguna",
        "ég tek töflurnar mínar á hverjum morgni", "ég meiddi mig á hnénu"
    ])
}
