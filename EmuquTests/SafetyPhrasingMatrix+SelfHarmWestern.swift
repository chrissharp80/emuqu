@testable import Emuqu
import Foundation

// English, German, French, Spanish, Brazilian Portuguese, Italian and Dutch.
// German, Italian and Spanish each have a colloquial verb the wish patterns
// alone miss ("bring mich um", "mi ammazzo", "me voy a matar"), and each has
// the same verb as a training idiom ("matarse a entrenar", "mi ammazzo di
// allenamenti"), so both sit in the row.

extension SafetyPhrasingMatrix {
    static let selfHarmWestern: [Row<SelfHarmForm>] = [english, german, french, spanish, portuguese, italian, dutch]

    private static let english = Row<SelfHarmForm>(language: "en", cells: [
        .passiveWish: ["I wish I was dead", "I wish I could go to sleep and never wake up", "I'd rather be dead"],
        .activeWish: ["I want to kill myself", "I wanna die", "I want to end my life"],
        .declaredIntent: ["I will kill myself", "I'm going to kill myself", "I'm gonna kill myself", "I'll kill myself", "I’m going to take my own life"],
        .planWithMethod: ["I'm going to hang myself", "I'm going to jump off the bridge", "I'm planning to take all my pills at once"],
        .planWithTime: ["I'm going to end it tonight", "tomorrow I'm going to kill myself", "I'll end my life this weekend"],
        .preparatoryAct: ["I've been saving up my pills", "I wrote a suicide note", "I've written goodbye letters to my family", "I've been stockpiling sleeping pills"],
        .pastAttempt: ["I tried to kill myself last year", "I took a bunch of pills", "I overdosed last night", "I attempted suicide"],
        .hopelessness: ["everyone would be better off without me", "I'm just a burden to everyone", "there's no point in living anymore"],
        .notWantingToBeHere: ["I don't want to be here any more", "I don't want to be here anymore", "I dont wanna be here anymore", "I don’t want to be here any more"],
        .selfInjury: ["I've been cutting myself", "I want to hurt myself", "I burn myself on purpose", "I cut myself on purpose"],
        .methodQuestion: ["what's a lethal dose of paracetamol", "how many sleeping pills would kill me", "how much insulin does it take to die"]
    ], negatives: [
        "this hill is killing me", "I'm killing myself on these intervals", "that workout killed me", "I'm dying after that run",
        "I'm going to end it here, my legs are gone", "I'm going to kill it at the race tomorrow", "I hurt myself on the trail",
        "suicide sprints tomorrow", "cutting myself some slack today", "I took my pills this morning",
        "I'd be better off without the heavy shoes", "the hill I want to die on is negative splits",
        "I took a bunch of salt tablets on the long run"
    ])

    private static let german = Row<SelfHarmForm>(language: "de", cells: [
        .passiveWish: ["ich wäre lieber tot", "ich wünschte, ich wäre tot", "ich will einfach nicht mehr aufwachen"],
        .activeWish: ["ich will mich umbringen", "ich will sterben", "ich möchte mir das Leben nehmen"],
        .declaredIntent: ["ich werde mich umbringen", "ich bring mich um", "ich bringe mich um", "ich nehme mir das Leben", "ich werde mir das Leben nehmen"],
        .planWithMethod: ["ich werde mich erhängen", "ich springe von der Brücke", "ich werde alle meine Tabletten auf einmal nehmen"],
        .planWithTime: ["heute Nacht bringe ich mich um", "morgen mache ich Schluss mit meinem Leben"],
        .preparatoryAct: ["ich habe einen Abschiedsbrief geschrieben", "ich sammle schon Tabletten", "ich habe Tabletten gehortet"],
        .pastAttempt: ["ich habe versucht, mich umzubringen", "ich habe eine Überdosis genommen", "ich hatte einen Suizidversuch"],
        .hopelessness: ["alle wären ohne mich besser dran", "ich bin nur eine Last für alle", "mein Leben hat keinen Sinn mehr"],
        .notWantingToBeHere: ["ich will nicht mehr hier sein", "ich möchte nicht mehr da sein"],
        .selfInjury: ["ich ritze mich", "ich will mich selbst verletzen", "ich habe mich absichtlich geschnitten"],
        .methodQuestion: ["was ist eine tödliche Dosis Paracetamol", "wie viele Schlaftabletten sind tödlich", "wie viele Tabletten braucht man, um zu sterben"]
    ], negatives: [
        "das Training bringt mich um", "dieser Berg bringt mich noch um", "ich bringe mich um den Schlaf", "ich sterbe gleich, so steil ist das",
        "ich habe mich beim Laufen verletzt", "ich nehme jeden Morgen meine Tabletten", "der Anstieg macht mich fertig"
    ])

    private static let french = Row<SelfHarmForm>(language: "fr", cells: [
        .passiveWish: ["j'aimerais être mort", "je voudrais ne jamais me réveiller", "je préférerais être morte"],
        .activeWish: ["je veux me tuer", "je veux mourir", "j'ai envie d'en finir"],
        .declaredIntent: ["je vais me tuer", "je vais me suicider", "je vais mettre fin à mes jours", "je me tuerai", "j’vais me tuer"],
        .planWithMethod: ["je vais me pendre", "je vais sauter du pont", "je vais avaler tous mes médicaments"],
        .planWithTime: ["ce soir je vais me tuer", "je vais en finir ce soir", "demain je mets fin à mes jours"],
        .preparatoryAct: ["j'ai écrit une lettre d'adieu", "j'accumule des cachets", "je mets des médicaments de côté pour en finir"],
        .pastAttempt: ["j'ai essayé de me tuer", "j'ai fait une tentative de suicide", "j'ai pris trop de médicaments", "j'ai fait une overdose"],
        .hopelessness: ["tout le monde serait mieux sans moi", "je suis un fardeau pour tout le monde", "ma vie n'a plus de sens"],
        .notWantingToBeHere: ["je ne veux plus être là", "je veux plus être là"],
        .selfInjury: ["je me scarifie", "je veux me faire du mal", "je me coupe exprès"],
        .methodQuestion: ["quelle est la dose mortelle de paracétamol", "combien de somnifères faut-il pour mourir", "combien de cachets pour mourir"]
    ], negatives: [
        "cette côte me tue", "ça me tue ces intervalles", "je suis mort après cette séance", "je vais en finir avec cette séance",
        "je vais me tuer à la tâche cette semaine", "je me tue à te le dire", "je me suis fait mal à la cheville", "je prends mes cachets le matin"
    ])

    private static let spanish = Row<SelfHarmForm>(language: "es", cells: [
        .passiveWish: ["ojalá estuviera muerto", "quisiera dormirme y no despertar", "preferiría estar muerta"],
        .activeWish: ["quiero matarme", "quiero morirme", "quiero quitarme la vida"],
        .declaredIntent: ["voy a matarme", "me voy a matar", "me voy a suicidar", "me mataré", "me voy a quitar la vida"],
        .planWithMethod: ["me voy a ahorcar", "voy a tirarme del puente", "voy a tomarme todas las pastillas"],
        .planWithTime: ["esta noche me voy a matar", "mañana me quito la vida", "voy a acabar con todo esta noche"],
        .preparatoryAct: ["escribí una carta de despedida", "he estado guardando pastillas", "estoy juntando pastillas para matarme"],
        .pastAttempt: ["intenté matarme", "intenté suicidarme", "me tomé demasiadas pastillas", "tuve una sobredosis"],
        .hopelessness: ["todos estarían mejor sin mí", "soy una carga para todos", "mi vida no tiene sentido"],
        .notWantingToBeHere: ["ya no quiero estar aquí", "no quiero estar aquí nunca más"],
        .selfInjury: ["me corto los brazos", "me hago daño a propósito", "quiero hacerme daño"],
        .methodQuestion: ["cuál es la dosis letal de paracetamol", "cuántas pastillas hacen falta para morir", "cuántas pastillas para dormir me matarían"]
    ], negatives: [
        "esta cuesta me está matando", "me muero de cansancio", "esta semana voy a matarme a hacer cuestas", "me mato a entrenar todos los días",
        "me corto el pelo mañana", "me hice daño en la rodilla", "tomo mis pastillas por la mañana"
    ])

    private static let portuguese = Row<SelfHarmForm>(language: "pt-BR", cells: [
        .passiveWish: ["queria estar morto", "eu queria dormir e não acordar mais", "preferia estar morta"],
        .activeWish: ["quero me matar", "quero morrer", "quero tirar minha vida"],
        .declaredIntent: ["vou me matar", "eu vou me suicidar", "vou tirar minha própria vida", "eu vou me matar hoje"],
        .planWithMethod: ["vou me enforcar", "vou pular da ponte", "vou tomar todos os meus remédios de uma vez"],
        .planWithTime: ["hoje à noite eu vou me matar", "vou acabar com tudo hoje à noite", "amanhã eu tiro minha vida"],
        .preparatoryAct: ["escrevi uma carta de despedida", "estou juntando remédios para me matar", "tenho guardado comprimidos"],
        .pastAttempt: ["tentei me matar", "tentei suicídio", "tomei remédios demais", "tive uma overdose"],
        .hopelessness: ["todo mundo ficaria melhor sem mim", "sou um peso para todos", "minha vida não tem sentido"],
        .notWantingToBeHere: ["não quero mais estar aqui", "não quero estar aqui nunca mais"],
        .selfInjury: ["me corto de propósito", "quero me machucar", "me machuco de propósito"],
        .methodQuestion: ["qual é a dose letal de paracetamol", "quantos comprimidos precisa para morrer", "quantos remédios matam uma pessoa"]
    ], negatives: [
        "essa subida está me matando", "vou me matar de treinar essa semana", "morri depois do treino",
        "tomo meus remédios todo dia de manhã", "me machuquei no treino", "me cortei fazendo a barba"
    ])

    private static let italian = Row<SelfHarmForm>(language: "it", cells: [
        .passiveWish: ["vorrei essere morto", "vorrei addormentarmi e non svegliarmi più", "preferirei essere morta"],
        .activeWish: ["voglio uccidermi", "voglio morire", "voglio ammazzarmi"],
        .declaredIntent: ["mi ammazzo", "mi uccido", "mi ucciderò", "mi ammazzerò", "ho deciso di uccidermi", "sto per ammazzarmi"],
        .planWithMethod: ["mi impicco", "mi butto dal ponte", "prenderò tutte le mie pillole insieme"],
        .planWithTime: ["stasera mi ammazzo", "domani mi tolgo la vita", "stasera la faccio finita"],
        .preparatoryAct: ["ho scritto una lettera d'addio", "sto mettendo da parte le pillole", "ho comprato una corda per impiccarmi"],
        .pastAttempt: ["ho tentato di uccidermi", "ho provato ad ammazzarmi", "ho preso troppe pillole", "ho fatto un'overdose"],
        .hopelessness: ["starebbero tutti meglio senza di me", "sono un peso per tutti", "la mia vita non ha più senso"],
        .notWantingToBeHere: ["non voglio più essere qui", "non voglio più esserci"],
        .selfInjury: ["mi taglio le braccia", "voglio farmi del male", "mi faccio del male apposta"],
        .methodQuestion: ["qual è la dose letale di paracetamolo", "quante pillole servono per morire", "quanti sonniferi ci vogliono per morire"]
    ], negatives: [
        "questa salita mi uccide", "mi ammazzo di allenamenti", "sono morto dopo l'allenamento", "la faccio finita con le ripetute",
        "mi taglio i capelli domani", "mi sono fatto male al ginocchio", "prendo le pillole ogni mattina"
    ])

    private static let dutch = Row<SelfHarmForm>(language: "nl", cells: [
        .passiveWish: ["ik wou dat ik dood was", "ik wil gewoon niet meer wakker worden", "ik ben liever dood"],
        .activeWish: ["ik wil mezelf doden", "ik wil dood", "ik wil zelfmoord plegen"],
        .declaredIntent: ["ik ga mezelf van kant maken", "ik ga zelfmoord plegen", "ik ga mezelf doden", "ik ga een einde aan mijn leven maken"],
        .planWithMethod: ["ik ga mezelf ophangen", "ik spring van de brug", "ik ga al mijn pillen tegelijk innemen"],
        .planWithTime: ["vannacht maak ik er een einde aan", "morgen ga ik mezelf van kant maken"],
        .preparatoryAct: ["ik heb een afscheidsbrief geschreven", "ik spaar pillen op", "ik heb pillen verzameld om mezelf te doden"],
        .pastAttempt: ["ik heb geprobeerd mezelf van kant te maken", "ik heb een zelfmoordpoging gedaan", "ik heb te veel pillen genomen"],
        .hopelessness: ["iedereen is beter af zonder mij", "ik ben een last voor iedereen", "mijn leven heeft geen zin meer"],
        .notWantingToBeHere: ["ik wil hier niet meer zijn", "ik wil er niet meer zijn"],
        .selfInjury: ["ik snijd mezelf expres", "ik wil mezelf pijn doen", "ik doe mezelf expres pijn"],
        .methodQuestion: ["wat is een dodelijke dosis paracetamol", "hoeveel slaappillen zijn dodelijk", "hoeveel pillen heb je nodig om dood te gaan"]
    ], negatives: [
        "deze heuvel maakt me kapot", "ik ga dood na die training", "ik maak er een einde aan voor vandaag, mijn benen zijn op",
        "ik neem elke ochtend mijn pillen", "ik heb mezelf pijn gedaan bij het hardlopen", "ik sneed mezelf bij het koken"
    ])
}
