@testable import Emuqu
import Foundation

// What the input guard answers with the symptom, injury or rhythm reply, in
// English, German, French, Spanish, Brazilian Portuguese, Italian and Dutch.
// The negatives are the hard effort the same words describe.

extension SafetyPhrasingMatrix {
    static let inputWestern: [Row<InputForm>] = [english, german, french, spanish, portuguese, italian, dutch]

    private static let english = Row<InputForm>(language: "en", cells: [
        .chestPain: ["my chest hurts", "I have chest pain", "there's pressure in my chest"],
        .breathlessness: ["I can't breathe", "I'm short of breath"],
        .fainting: ["I fainted", "I passed out on my run", "I feel like I'm going to faint"],
        .severeSymptom: ["I'm having a panic attack", "I have severe pain"],
        .heartAttack: ["am I having a heart attack?", "I think I'm having a heart attack"],
        .stroke: ["am I having a stroke?", "I think I had a stroke"],
        .injury: ["I fell and hurt my ankle", "I think my wrist is broken", "I'm bleeding"],
        .atrialFibrillation: ["do I have atrial fibrillation?", "is this AFib?"],
        .irregularHeartbeat: ["my heart is skipping beats", "I have palpitations"],
        .dangerQuestion: ["is my heart rate dangerous?", "should I be worried about this?"]
    ], negatives: [
        "my legs are dead after that run", "that hill took my breath away", "I was out of breath on the last interval",
        "my chest is pumped after bench day", "I broke my 5k PR", "I fell behind the group", "my heart was pounding on the climb"
    ])

    private static let german = Row<InputForm>(language: "de", cells: [
        .chestPain: ["mir tut die Brust weh", "ich habe Brustschmerzen", "ich habe Druck auf der Brust"],
        .breathlessness: ["ich bekomme keine Luft", "ich habe Atemnot"],
        .fainting: ["ich bin ohnmächtig geworden", "ich bin beim Laufen umgekippt"],
        .severeSymptom: ["ich habe eine Panikattacke", "ich habe starke Schmerzen"],
        .heartAttack: ["habe ich einen Herzinfarkt?", "ich glaube, ich habe einen Herzinfarkt"],
        .stroke: ["habe ich einen Schlaganfall?", "ich glaube, ich hatte einen Schlaganfall"],
        .injury: ["ich bin gestürzt und habe mir den Knöchel verletzt", "ich glaube, mein Handgelenk ist gebrochen", "ich blute"],
        .atrialFibrillation: ["habe ich Vorhofflimmern?", "ist das Vorhofflimmern?"],
        .irregularHeartbeat: ["mein Herz stolpert", "ich habe einen unregelmäßigen Herzschlag"],
        .dangerQuestion: ["ist mein Puls gefährlich?", "sollte ich mir Sorgen machen?"]
    ], negatives: [
        "meine Beine sind tot nach dem Lauf", "ich war am Berg völlig außer Atem", "ich habe meine Bestzeit gebrochen",
        "mein Herz hat am Anstieg gepocht"
    ])

    private static let french = Row<InputForm>(language: "fr", cells: [
        .chestPain: ["j'ai mal à la poitrine", "j'ai une douleur thoracique", "j'ai une oppression dans la poitrine"],
        .breathlessness: ["je n'arrive pas à respirer", "j'ai du mal à respirer"],
        .fainting: ["je me suis évanoui", "j'ai perdu connaissance pendant ma course"],
        .severeSymptom: ["je fais une crise de panique", "j'ai une douleur intense"],
        .heartAttack: ["est-ce que je fais une crise cardiaque ?", "je crois que je fais un infarctus"],
        .stroke: ["est-ce que je fais un AVC ?", "je crois que j'ai fait un accident vasculaire cérébral"],
        .injury: ["je suis tombé et je me suis fait mal à la cheville", "je crois que mon poignet est cassé", "je saigne"],
        .atrialFibrillation: ["est-ce que j'ai de la fibrillation auriculaire ?", "est-ce de la FA ?"],
        .irregularHeartbeat: ["j'ai des palpitations", "mon cœur bat de façon irrégulière"],
        .dangerQuestion: ["est-ce que ma fréquence cardiaque est dangereuse ?", "dois-je m'inquiéter ?"]
    ], negatives: [
        "j'ai les jambes mortes après la sortie", "j'étais essoufflé dans la côte", "j'ai battu mon record", "mon cœur battait fort dans la montée"
    ])

    private static let spanish = Row<InputForm>(language: "es", cells: [
        .chestPain: ["me duele el pecho", "tengo dolor en el pecho", "siento presión en el pecho"],
        .breathlessness: ["no puedo respirar", "me falta el aire"],
        .fainting: ["me desmayé", "perdí el conocimiento corriendo"],
        .severeSymptom: ["tengo un ataque de pánico", "tengo un dolor intenso"],
        .heartAttack: ["¿estoy teniendo un infarto?", "creo que me está dando un ataque cardíaco"],
        .stroke: ["¿estoy teniendo un ictus?", "creo que tuve un derrame cerebral"],
        .injury: ["me caí y me lastimé el tobillo", "creo que me rompí la muñeca", "estoy sangrando"],
        .atrialFibrillation: ["¿tengo fibrilación auricular?", "¿esto es fibrilación auricular?"],
        .irregularHeartbeat: ["tengo palpitaciones", "el corazón me late de forma irregular"],
        .dangerQuestion: ["¿es peligrosa mi frecuencia cardíaca?", "¿debería preocuparme?"]
    ], negatives: [
        "tengo las piernas muertas después de correr", "me quedé sin aliento en la cuesta", "rompí mi récord", "el corazón me latía fuerte en la subida"
    ])

    private static let portuguese = Row<InputForm>(language: "pt-BR", cells: [
        .chestPain: ["meu peito está doendo", "estou com dor no peito", "sinto um aperto no peito"],
        .breathlessness: ["não consigo respirar", "estou sem ar"],
        .fainting: ["eu desmaiei", "perdi a consciência correndo"],
        .severeSymptom: ["estou tendo um ataque de pânico", "estou com uma dor intensa"],
        .heartAttack: ["estou tendo um infarto?", "acho que estou tendo um ataque cardíaco"],
        .stroke: ["estou tendo um AVC?", "acho que tive um derrame"],
        .injury: ["caí e machuquei o tornozelo", "acho que quebrei o pulso", "estou sangrando"],
        .atrialFibrillation: ["eu tenho fibrilação atrial?", "isso é fibrilação atrial?"],
        .irregularHeartbeat: ["estou com palpitações", "meu coração está batendo de forma irregular"],
        .dangerQuestion: ["minha frequência cardíaca é perigosa?", "devo me preocupar?"]
    ], negatives: [
        "minhas pernas estão mortas depois da corrida", "fiquei sem fôlego na subida", "quebrei meu recorde", "meu coração disparou na subida"
    ])

    private static let italian = Row<InputForm>(language: "it", cells: [
        .chestPain: ["mi fa male il petto", "ho un dolore al petto", "sento un peso sul petto"],
        .breathlessness: ["non riesco a respirare", "ho difficoltà a respirare"],
        .fainting: ["sono svenuto", "ho perso i sensi mentre correvo"],
        .severeSymptom: ["ho un attacco di panico", "ho un dolore intenso"],
        .heartAttack: ["sto avendo un infarto?", "credo di avere un attacco cardiaco"],
        .stroke: ["sto avendo un ictus?", "credo di aver avuto un ictus"],
        .injury: ["sono caduto e mi sono fatto male alla caviglia", "credo di essermi rotto il polso", "sto sanguinando"],
        .atrialFibrillation: ["ho la fibrillazione atriale?", "questa è fibrillazione atriale?"],
        .irregularHeartbeat: ["ho le palpitazioni", "il cuore mi batte in modo irregolare"],
        .dangerQuestion: ["la mia frequenza cardiaca è pericolosa?", "devo preoccuparmi?"]
    ], negatives: [
        "ho le gambe morte dopo la corsa", "ero senza fiato in salita", "ho battuto il mio record", "il cuore mi batteva forte in salita"
    ])

    private static let dutch = Row<InputForm>(language: "nl", cells: [
        .chestPain: ["mijn borst doet pijn", "ik heb pijn op de borst", "ik voel druk op mijn borst"],
        .breathlessness: ["ik krijg geen lucht", "ik kan niet ademen"],
        .fainting: ["ik ben flauwgevallen", "ik viel flauw tijdens het hardlopen"],
        .severeSymptom: ["ik heb een paniekaanval", "ik heb hevige pijn"],
        .heartAttack: ["heb ik een hartaanval?", "ik denk dat ik een hartaanval heb"],
        .stroke: ["heb ik een beroerte?", "ik denk dat ik een herseninfarct heb gehad"],
        .injury: ["ik ben gevallen en heb mijn enkel bezeerd", "ik denk dat mijn pols gebroken is", "ik bloed"],
        .atrialFibrillation: ["heb ik boezemfibrilleren?", "is dit atriumfibrilleren?"],
        .irregularHeartbeat: ["ik heb hartkloppingen", "mijn hart slaat onregelmatig"],
        .dangerQuestion: ["is mijn hartslag gevaarlijk?", "moet ik me zorgen maken?"]
    ], negatives: [
        "mijn benen zijn dood na de loop", "ik was buiten adem op de heuvel", "ik heb mijn record verbroken", "mijn hart bonsde op de klim"
    ])
}
