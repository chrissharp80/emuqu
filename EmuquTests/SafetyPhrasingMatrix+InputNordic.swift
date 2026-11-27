@testable import Emuqu
import Foundation

// The input-guard columns in Danish, Norwegian Bokmål, Swedish, Finnish and
// Icelandic.

extension SafetyPhrasingMatrix {
    static let inputNordic: [Row<InputForm>] = [danish, norwegian, swedish, finnish, icelandic]

    private static let danish = Row<InputForm>(language: "da", cells: [
        .chestPain: ["jeg har ondt i brystet", "jeg har brystsmerter"],
        .breathlessness: ["jeg kan ikke få vejret", "jeg har åndenød"],
        .fainting: ["jeg besvimede", "jeg faldt om under løbet"],
        .severeSymptom: ["jeg har et panikanfald", "jeg har kraftige smerter"],
        .heartAttack: ["har jeg et hjerteanfald?", "jeg tror, jeg har et hjerteanfald"],
        .stroke: ["har jeg en blodprop i hjernen?", "jeg tror, jeg har haft en hjerneblødning"],
        .injury: ["jeg faldt og slog min ankel", "jeg tror, mit håndled er brækket", "jeg bløder"],
        .atrialFibrillation: ["har jeg atrieflimren?", "er det her atrieflimmer?"],
        .irregularHeartbeat: ["mit hjerte slår uregelmæssigt", "jeg har uregelmæssig hjerterytme"],
        .dangerQuestion: ["er min puls farlig?", "skal jeg være bekymret?"]
    ], negatives: [
        "mine ben er døde efter løbet", "jeg var forpustet på bakken", "jeg slog min rekord", "mit hjerte hamrede på stigningen"
    ])

    private static let norwegian = Row<InputForm>(language: "nb", cells: [
        .chestPain: ["jeg har vondt i brystet", "jeg har brystsmerter"],
        .breathlessness: ["jeg får ikke puste", "jeg har åndenød"],
        .fainting: ["jeg besvimte", "jeg svimte av under løpet"],
        .severeSymptom: ["jeg har et panikkanfall", "jeg har kraftige smerter"],
        .heartAttack: ["har jeg et hjerteinfarkt?", "jeg tror jeg har hjerteinfarkt"],
        .stroke: ["har jeg hjerneslag?", "jeg tror jeg har hatt et hjerneslag"],
        .injury: ["jeg falt og skadet ankelen", "jeg tror håndleddet er brukket", "jeg blør"],
        .atrialFibrillation: ["har jeg atrieflimmer?", "er dette atrieflimmer?"],
        .irregularHeartbeat: ["hjertet slår uregelmessig", "jeg har uregelmessig hjerterytme"],
        .dangerQuestion: ["er pulsen min farlig?", "skal jeg være bekymret?"]
    ], negatives: [
        "beina er døde etter løpet", "jeg var andpusten i bakken", "jeg slo rekorden min", "hjertet hamret i motbakken"
    ])

    private static let swedish = Row<InputForm>(language: "sv", cells: [
        .chestPain: ["jag har ont i bröstet", "jag har bröstsmärtor"],
        .breathlessness: ["jag kan inte andas", "jag har andnöd"],
        .fainting: ["jag svimmade", "jag tappade medvetandet under löpningen"],
        .severeSymptom: ["jag har en panikattack", "jag har svår smärta"],
        .heartAttack: ["har jag en hjärtinfarkt?", "jag tror att jag har en hjärtinfarkt"],
        .stroke: ["har jag en stroke?", "jag tror att jag har haft en hjärnblödning"],
        .injury: ["jag ramlade och skadade fotleden", "jag tror att handleden är bruten", "jag blöder"],
        .atrialFibrillation: ["har jag förmaksflimmer?", "är det här förmaksflimmer?"],
        .irregularHeartbeat: ["hjärtat slår oregelbundet", "jag har oregelbunden hjärtrytm"],
        .dangerQuestion: ["är min puls farlig?", "ska jag vara orolig?"]
    ], negatives: [
        "benen är döda efter löpningen", "jag var andfådd i backen", "jag slog mitt rekord", "hjärtat bultade i uppförsbacken"
    ])

    private static let finnish = Row<InputForm>(language: "fi", cells: [
        .chestPain: ["rintaan sattuu", "minulla on rintakipua"],
        .breathlessness: ["en saa henkeä", "minulla on hengenahdistusta"],
        .fainting: ["pyörryin", "menetin tajuntani juoksulenkillä"],
        .severeSymptom: ["minulla on paniikkikohtaus", "minulla on kova kipu"],
        .heartAttack: ["onko minulla sydäninfarkti?", "luulen että saan sydänkohtauksen"],
        .stroke: ["onko minulla aivohalvaus?", "luulen että sain aivoinfarktin"],
        .injury: ["kaaduin ja loukkasin nilkkani", "luulen että ranteeni on murtunut", "vuodan verta"],
        .atrialFibrillation: ["onko minulla eteisvärinä?", "onko tämä eteisvärinää?"],
        .irregularHeartbeat: ["sydämeni lyö epäsäännöllisesti", "minulla on sydämentykytystä"],
        .dangerQuestion: ["onko sykkeeni vaarallinen?", "pitäisikö minun huolestua?"]
    ], negatives: [
        "jalat ovat kuolleet lenkin jälkeen", "olin hengästynyt mäessä", "rikoin ennätykseni", "sydän hakkasi ylämäessä"
    ])

    private static let icelandic = Row<InputForm>(language: "is", cells: [
        .chestPain: ["ég er með verk í brjóstinu", "ég er með brjóstverk"],
        .breathlessness: ["ég get ekki andað", "ég næ ekki andanum"],
        .fainting: ["það leið yfir mig", "ég missti meðvitund á hlaupum"],
        .severeSymptom: ["ég er með kvíðakast", "ég er með mikla verki"],
        .heartAttack: ["er ég að fá hjartaáfall?", "ég held að ég sé að fá hjartaáfall"],
        .stroke: ["er ég að fá heilablóðfall?", "ég held að ég hafi fengið heilablóðfall"],
        .injury: ["ég datt og meiddi mig á ökklanum", "ég held að úlnliðurinn sé brotinn", "það blæðir úr mér"],
        .atrialFibrillation: ["er ég með gáttatif?", "er þetta gáttatif?"],
        .irregularHeartbeat: ["hjartað slær óreglulega", "ég er með hjartsláttaróreglu"],
        .dangerQuestion: ["er púlsinn minn hættulegur?", "er þetta hættulegt?"]
    ], negatives: [
        "fæturnir eru dauðir eftir hlaupið", "ég var móður í brekkunni", "ég bætti metið mitt", "hjartað barðist í brekkunni"
    ])
}
