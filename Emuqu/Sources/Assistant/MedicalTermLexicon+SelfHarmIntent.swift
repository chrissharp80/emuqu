import Foundation

// MARK: - Self-harm intent and warning signs (input side)
//
// The wish phrasings in `MedicalTermLexicon+SelfHarm.swift` miss most of what
// the Columbia Suicide Severity Rating Scale and safe-messaging guidance treat
// as the warning signs: a declared intent with no wish verb ("I will kill
// myself", "je vais me tuer", "ich bring mich um", "mi ammazzo", "tapan
// itseni"), a preparatory act (pills saved up, a goodbye letter), feeling a
// burden ("everyone would be better off without me"), not wanting to be here
// any more, deliberate self-injury, and asking for a lethal dose. These are
// those forms for every shipped language, appended to `selfHarmActsAndPlans`.
//
// The training idioms that share the verbs stay out by shape, not by list:
// the declared intent needs the speaker as the one doing it to themself
// (reflexive pronoun, or the first person before a reflexive verb), so a hill
// that "bringt mich um", "tar livet av meg" or "mi uccide" never matches; a
// colloquial verb that also means working hard ("matarse a entrenar", "mi
// ammazzo di allenamenti", "me tuer à la tâche", "me matar de treinar") is
// excluded by the construction that follows it; a jump needs a height and no
// water after it; a pill count needs a medicine noun, never "salt tablets".
extension MedicalTermLexicon {
    static let selfHarmIntentAndSigns: [String] = englishSelfHarmSigns + germanicSelfHarmSigns + romanceSelfHarmSigns
        + nordicSelfHarmSigns + russianSelfHarmSigns

    private static let englishSelfHarmSigns: [String] = [
        "(?:i['’]?d|i\\s+would)\\s+(?:rather|sooner)\\s+be\\s+dead", "wish\\s+i\\s+(?:had\\s+)?(?:was|were|had\\s+been)\\s+never\\s+born",
        "(?:don['’]?t|do\\s+not)\\s+(?:want\\s+to|wanna)\\s+be\\s+(?:here|around|alive)\\s+(?:any\\s*more|any\\s+longer)",
        "better\\s+off\\s+without\\s+me", "(?:i['’]?m|i\\s+am|i\\s+feel\\s+like)\\s+(?:just\\s+|only\\s+|such\\s+)?a\\s+burden\\s+(?:to|on|for)\\b",
        "no\\s+(?:point|reason)\\s+(?:in\\s+)?(?:living|being\\s+alive|going\\s+on\\s+living)",
        "(?:saving\\s+up|stockpiling|hoarding|stashing|collecting)\\s+(?:my\\s+|some\\s+|the\\s+)?(?:\\w+\\s+)?(?:pills|meds|tablets|medications?|painkillers|sleeping\\s+pills)",
        "(?:goodbye|farewell)\\s+(?:letters?|notes?)\\s+(?:to|for)\\s+(?:my|everyone|everybody)",
        "(?:wrote|written|writing|write)\\s+(?:a\\s+|my\\s+)?(?:goodbye|farewell)\\s+(?:letters?|notes?)",
        "(?:cut|cutting|burn|burning|burned|burnt|hit|hitting|hurt|hurting|harm|scratch|scratching)\\s+myself\\s+(?:on\\s+purpose|deliberately|intentionally)",
        "i(?:['’]?ve|\\s+have)?\\s+(?:just\\s+)?overdosed\\s+(?:last\\s+night|yesterday|this\\s+morning|earlier|again|today|tonight|before|once|twice)",
        "(?:took|taken|swallowed|downed)\\s+(?:a\\s+(?:bunch|lot|load|ton)\\s+of|loads\\s+of|lots\\s+of|tons\\s+of)\\s+(?:my\\s+|the\\s+)?"
            + "(?!(?:salt|electrolyte|vitamin|caffeine|iron|magnesium)\\s)(?:\\w+\\s+)?(?:pills|meds|medications?|tablets|painkillers|sleeping\\s+pills)",
        "(?:take|taking|swallow|swallowing)\\s+all\\s+(?:of\\s+)?(?:my|the)\\s+(?:\\w+\\s+)?(?:pills|meds|medications?|tablets|painkillers)\\s+at\\s+once",
        "(?:lethal|fatal|deadly)\\s+(?:dose|amount|overdose)",
        "how\\s+(?:many|much)\\s+(?:\\w+\\s+){0,2}(?:pills|tablets|meds|medications?|medicines?|insulin|paracetamol|tylenol|acetaminophen|ibuprofen|aspirin|painkillers|antidepressants)"
            + "\\b[^.?!]{0,40}?(?:kill\\s+(?:me|myself|a\\s+person|someone|you)|to\\s+die|be\\s+(?:fatal|lethal)|overdose)"
    ]

    private static let germanicSelfHarmSigns: [String] = [
        // de
        "w[äa]re\\s+(?:lieber|am\\s+liebsten)\\s+tot", "w[üu]nschte,?\\s+ich\\s+w[äa]re\\s+tot",
        "(?:will|m[öo]chte|moechte)\\s+(?:einfach\\s+|nur\\s+)?nicht\\s+mehr\\s+(?:aufwachen|hier\\s+sein|da\\s+sein|existieren)",
        "(?:werde|werd)\\s+mich\\s+(?:umbringen|t[öo]ten|erh[äa]ngen|vergiften|selbst\\s+verletzen)", "(?:werde|werd)\\s+mir\\s+das\\s+leben\\s+nehmen",
        "(?:ich\\s+bring(?:e)?|bring(?:e)?\\s+ich)\\s+mich\\s+um(?!\\s+(?:den|die|das|mein\\w*)\\b)", "(?:ich\\s+nehme|nehme\\s+ich)\\s+mir\\s+das\\s+leben",
        "(?:springe?|werfe?)\\s+(?:mich\\s+)?(?:von|vor)\\s+(?:der|die|einer|eine|den|dem|einen)\\s+(?:br[üu]cke|zug|dach|hochhaus|klippe|u-bahn)(?!\\s+ins\\s+wasser)",
        "alle\\s+(?:meine\\s+)?(?:tabletten|pillen|medikamente|schlaftabletten)\\s+(?:auf\\s+einmal|gleichzeitig)",
        "abschiedsbrief\\w*",
        "(?:sammle|sammele|horte|hamstere|bunkere)\\s+(?:\\w+\\s+){0,2}(?:tabletten|pillen|medikamente|schlaftabletten)",
        "(?:tabletten|pillen|medikamente|schlaftabletten)\\s+(?:gehortet|gesammelt|gebunkert|gehamstert)",
        "ohne\\s+mich\\s+(?:besser\\s+dran|besser\\s+aufgehoben|gl[üu]cklicher)", "(?:bin|w[äa]re)\\s+(?:nur\\s+|blo[ßs]\\s+)?eine\\s+last\\s+f[üu]r",
        "(?:mein\\s+)?leben\\s+hat\\s+keinen\\s+sinn(?:\\s+mehr)?", "keinen\\s+sinn\\s+mehr\\s+zu\\s+leben",
        "ritze\\s+mich", "(?:mich|ich\\s+mich)\\s+(?:absichtlich|mit\\s+absicht|bewusst)\\s+(?:geschnitten|verletzt|verbrannt|geritzt)",
        "(?:schneide|verletze|verbrenne)\\s+mich\\s+(?:absichtlich|mit\\s+absicht|selbst)",
        "(?:t[öo]dliche|letale)\\s+dosis",
        "wie\\s*viele?\\s+(?:\\w+\\s+){0,2}(?:tabletten|pillen|schlaftabletten|medikamente)\\b[^.?!]{0,40}?(?:t[öo]dlich|zu\\s+sterben|umzubringen)",
        // nl
        "wou\\s+dat\\s+ik\\s+dood\\s+was", "(?:ben|was)\\s+liever\\s+dood",
        "(?:wil|zou\\s+willen)\\s+(?:gewoon\\s+)?niet\\s+meer\\s+wakker\\s+worden", "wil\\s+(?:hier|er)\\s+niet\\s+meer\\s+zijn",
        "(?:spring|springen)\\s+(?:van|voor)\\s+(?:de|een)\\s+(?:brug|trein|flat|toren|dak)(?!\\s+in\\s+het\\s+water)",
        "al\\s+mijn\\s+(?:pillen|tabletten|medicijnen|slaappillen)\\s+(?:tegelijk|in\\s+(?:[ée][ée]n|een)\\s+keer)",
        "(?:vannacht|vanavond|morgen)\\s+maak\\s+ik\\s+er\\s+een\\s+einde\\s+aan", "afscheidsbrie[fv]\\w*",
        "spaar\\s+(?:\\w+\\s+)?(?:pillen|tabletten|medicijnen|slaappillen)\\s+op",
        "beter\\s+af\\s+zonder\\s+mij", "(?:ben|voel\\s+me)\\s+(?:alleen\\s+maar\\s+)?een\\s+last\\s+voor",
        "(?:mijn\\s+)?leven\\s+heeft\\s+geen\\s+zin(?:\\s+meer)?",
        "(?:snijd|snij|sneed|brand|doe)\\s+mezelf\\s+(?:expres|opzettelijk|met\\s+opzet|bewust)",
        "dodelijke\\s+dosis", "hoeveel\\s+(?:\\w+\\s+){0,2}(?:pillen|tabletten|slaappillen|medicijnen|paracetamol)\\b[^.?!]{0,40}?(?:dodelijk|dood\\s+te\\s+gaan|te\\s+sterven)"
    ]

    private static let romanceSelfHarmSigns: [String] = [
        // fr
        "(?:j['’]\\s*aimerais(?:\\s+mieux)?|je\\s+voudrais|je\\s+pr[ée]f[ée]rerais)\\s+[êe]tre\\s+mort(?:e)?",
        "(?:ne\\s+jamais|ne\\s+plus|plus\\s+jamais)\\s+me\\s+r[ée]veiller(?!\\s+(?:[àa]|avant|si|aussi|t[ôo]t)\\b)",
        "(?:je\\s+|j['’]\\s*)vais\\s+me\\s+(?:tuer|suicider|pendre|foutre\\s+en\\s+l['’]air)(?!\\s+(?:[àa]\\s+la\\s+t[âa]che|au\\s+travail|[àa]\\s+l['’]entra[îi]nement))",
        "je\\s+me\\s+(?:tuerai|suiciderai|pendrai)", "(?:mets|mettrai|vais\\s+mettre)\\s+fin\\s+[àa]\\s+(?:mes\\s+jours|ma\\s+vie)",
        "sauter\\s+(?:du|d['’]un|de\\s+la|d['’]une|par\\s+la)\\s+(?:pont|immeuble|toit|falaise|fen[êe]tre)(?!\\s+dans\\s+(?:l['’]eau|la\\s+rivi[èe]re|le\\s+lac))",
        "aval(?:er|e)\\s+tou(?:s|tes)\\s+(?:mes|les)\\s+(?:m[ée]dicaments|cachets|pilules|comprim[ée]s|somnif[èe]res)",
        "lettre\\s+d['’]\\s*adieu",
        "(?:accumul\\w*|(?:mets|mis|mettre)\\s+de\\s+c[ôo]t[ée])\\s+(?:des\\s+|mes\\s+)?(?:m[ée]dicaments|cachets|pilules|comprim[ée]s|somnif[èe]res)",
        "(?:m[ée]dicaments|cachets|pilules|comprim[ée]s|somnif[èe]res)\\s+de\\s+c[ôo]t[ée]",
        "(?:essay[ée]|tent[ée])\\s+de\\s+me\\s+(?:tuer|suicider|pendre)",
        "(?:serait|seraient|serais|sera|seront)\\s+mieux\\s+sans\\s+moi", "(?:suis|[êe]tre)\\s+un\\s+(?:fardeau|poids)\\s+pour",
        "(?:ma\\s+)?vie\\s+n['’]a\\s+(?:plus\\s+)?(?:de|aucun)\\s+sens", "(?:ne\\s+)?veux\\s+plus\\s+[êe]tre\\s+l[àa]",
        "me\\s+scarifi\\w*", "scarification\\w*",
        "me\\s+(?:coupe|br[ûu]le|fais\\s+du\\s+mal|blesse)\\s+(?:expr[èe]s|volontairement|d[ée]lib[ée]r[ée]ment)",
        "dose\\s+(?:mortelle|l[ée]tale)",
        "combien\\s+de\\s+(?:\\w+\\s+){0,2}(?:m[ée]dicaments|cachets|pilules|comprim[ée]s|somnif[èe]res|parac[ée]tamol|doliprane)\\b[^.?!]{0,40}?(?:mourir|me\\s+tuer|mortel\\w*)",
        // es
        "ojal[áa]\\s+(?:estuviera|estuviese)\\s+muert[oa]", "(?:preferir[íi]a|quisiera|quiero)\\s+estar\\s+muert[oa]",
        "(?:dormirme|dormir)\\s+y\\s+no\\s+(?:volver\\s+a\\s+)?despertar(?:me)?", "no\\s+despertar(?:me)?\\s+nunca\\s+m[áa]s",
        "voy\\s+a\\s+(?:matarme(?!\\s+a\\s+\\w+(?:ar|er|ir)\\b)|suicidarme|ahorcarme|quitarme\\s+la\\s+vida)",
        "me\\s+voy\\s+a\\s+(?:matar(?!\\s+a\\s+\\w+(?:ar|er|ir)\\b)|suicidar|ahorcar|quitar\\s+la\\s+vida)",
        "me\\s+(?:matar[ée]|suicidar[ée]|ahorcar[ée])", "me\\s+(?:quito|quitar[ée])\\s+la\\s+vida",
        "tirarme\\s+(?:del|de\\s+un|desde\\s+el|desde\\s+un|por\\s+la)\\s+(?:puente|edificio|balc[óo]n|ventana|techo|azotea|acantilado)(?!\\s+al\\s+(?:agua|r[íi]o|mar|lago))",
        "tomarme\\s+todas\\s+(?:las|mis)\\s+(?:pastillas|p[íi]ldoras|medicinas|medicamentos)(?!\\s+(?:del\\s+d[íi]a|de\\s+la\\s+semana))",
        "carta\\s+de\\s+despedida",
        "(?:guardando|juntando|acumulando|guardo|junto|acumulo|guardado|juntado|acumulado)\\s+(?:\\w+\\s+)?(?:pastillas|p[íi]ldoras|medicamentos|pastis)",
        "intent[ée]\\s+(?:matarme|suicidarme|quitarme\\s+la\\s+vida|ahorcarme)", "tuve\\s+una\\s+sobredosis",
        "(?:estar[íi]an|estar[íi]a|estar[áa]n|estar[áa])\\s+mejor\\s+sin\\s+m[íi]", "soy\\s+una\\s+carga\\s+para",
        "(?:mi\\s+)?vida\\s+no\\s+tiene\\s+(?:ning[úu]n\\s+)?sentido", "no\\s+tiene\\s+sentido\\s+vivir",
        "no\\s+quiero\\s+estar\\s+aqu[íi]\\s+(?:nunca\\s+)?m[áa]s", "ya\\s+no\\s+quiero\\s+(?:estar\\s+aqu[íi]|existir)",
        "me\\s+corto\\s+(?:los\\s+brazos|las\\s+mu[ñn]ecas|las\\s+piernas|la\\s+piel)",
        "me\\s+(?:hago|hice|corto|quemo|lastimo|cort[ée]|quem[ée]|lastim[ée])\\s+(?:da[ñn]o\\s+)?(?:a\\s+prop[óo]sito|adrede|queriendo)",
        "dosis\\s+(?:letal|mortal)",
        "cu[áa]nt[oa]s\\s+(?:\\w+\\s+){0,2}(?:pastillas|p[íi]ldoras|medicamentos|paracetamol|ibuprofeno|insulina)\\b[^.?!]{0,40}?(?:morir|me\\s+matar[íi]an|matan|matar[íi]an|matarme|mortales)",
        // pt-BR
        "(?:queria|preferia|gostaria\\s+de)\\s+estar\\s+mort[oa]", "dormir\\s+e\\s+n[ãa]o\\s+acordar", "n[ãa]o\\s+acordar\\s+nunca\\s+mais",
        "vou\\s+me\\s+(?:matar|suicidar|enforcar)(?!\\s+(?:de\\s+\\w+(?:ar|er|ir)|de\\s+tanto|no\\s+treino|na\\s+academia)\\b)",
        "(?:vou\\s+tirar|tiro|tirarei)\\s+(?:a\\s+)?minha\\s+(?:pr[óo]pria\\s+)?vida",
        "pular\\s+(?:da|de\\s+uma|do|de\\s+um)\\s+(?:ponte|pr[ée]dio|janela|sacada|viaduto|penhasco)(?!\\s+(?:no|na)\\s+(?:[áa]gua|rio|mar|lago|piscina))",
        "(?:tomar|tomei)\\s+todos\\s+os\\s+(?:meus\\s+)?(?:rem[ée]dios|comprimidos|p[íi]lulas)\\s+de\\s+(?:uma\\s+)?vez",
        "(?:juntando|guardando|acumulando|guardado|juntado|acumulado|junto|guardo)\\s+(?:\\w+\\s+)?(?:rem[ée]dios|comprimidos|p[íi]lulas)",
        "tentei\\s+(?:me\\s+matar|suic[íi]dio|me\\s+suicidar|me\\s+enforcar|tirar\\s+(?:a\\s+)?minha\\s+vida)", "tive\\s+uma\\s+overdose",
        "(?:ficaria|ficariam|estaria|estariam|seria|seriam)\\s+melhor(?:es)?\\s+sem\\s+mim", "sou\\s+um\\s+(?:peso|fardo)\\s+para",
        "(?:minha\\s+)?vida\\s+n[ãa]o\\s+tem\\s+(?:mais\\s+)?sentido",
        "n[ãa]o\\s+quero\\s+(?:mais\\s+(?:estar\\s+aqui|existir)|estar\\s+aqui\\s+nunca\\s+mais)",
        "me\\s+(?:corto|machuco|queimo|cortei|machuquei|queimei)\\s+de\\s+prop[óo]sito",
        "dose\\s+(?:letal|fatal)",
        "quant[oa]s\\s+(?:\\w+\\s+){0,2}(?:comprimidos|rem[ée]dios|p[íi]lulas|paracetamol)\\b[^.?!]{0,40}?(?:morrer|matam|mata)",
        // it
        "(?:vorrei|preferirei)\\s+essere\\s+mort[oa]", "non\\s+svegliarmi\\s+pi[ùu]",
        "mi\\s+(?:ammazzo|uccido|suicido)(?!\\s+(?:di|dal|dalla|dalle|dai|dagli|a|per|con)\\b)",
        "mi\\s+(?:ammazzer[òo]|uccider[òo]|suicider[òo]|impiccher[òo]|toglier[òo]\\s+la\\s+vita)", "mi\\s+tolgo\\s+la\\s+vita", "mi\\s+impicco",
        "(?:deciso\\s+di|sto\\s+per|intenzione\\s+di|(?:tentato|provato)\\s+(?:di|ad?))\\s+(?:uccidermi|ammazzarmi|suicidarmi|togliermi\\s+la\\s+vita|impiccarmi)",
        "mi\\s+butto\\s+(?:dal\\s+(?:ponte|palazzo|balcone|tetto)|dalla\\s+finestra|sotto\\s+(?:un|il)\\s+treno)(?!\\s+(?:nel|in)\\s+(?:fiume|lago|mare|acqua))",
        "(?:prendere|prender[òo]|ingoiare|ingoier[òo])\\s+tutte\\s+le\\s+(?:mie\\s+)?(?:pillole|pastiglie|compresse|medicine)\\s+(?:insieme|in\\s+una\\s+volta|d['’]un\\s+colpo)",
        "lettera\\s+d['’]\\s*addio",
        "(?:mettendo|messo|metto)\\s+da\\s+parte\\s+(?:le\\s+|delle\\s+)?(?:pillole|pastiglie|compresse|medicine|sonniferi)",
        "meglio\\s+senza\\s+di\\s+me", "sono\\s+un\\s+(?:peso|fardello)\\s+per",
        "(?:la\\s+mia\\s+)?vita\\s+non\\s+ha\\s+(?:pi[ùu]\\s+)?(?:alcun\\s+)?senso",
        "non\\s+voglio\\s+pi[ùu]\\s+(?:essere\\s+qui|esserci|esistere)",
        "mi\\s+taglio\\s+(?:le\\s+braccia|i\\s+polsi|le\\s+gambe|apposta)",
        "mi\\s+(?:faccio|sono\\s+fatt[oa])\\s+del\\s+male\\s+(?:apposta|di\\s+proposito|volontariamente)",
        "dose\\s+(?:letale|mortale)",
        "quant[ei]\\s+(?:\\w+\\s+){0,2}(?:pillole|pastiglie|compresse|sonniferi|medicine|farmaci)\\b[^.?!]{0,40}?(?:morire|uccider(?:mi|si)|uccidono|letal[ei])"
    ]

    private static let nordicSelfHarmSigns: [String] = [
        // da, nb: "slå mig selv ihjel" in every tense; the idiom has no "selv".
        "sl(?:[åa]r?|og)\\s+(?:jeg\\s+)?(?:mig|meg)\\s+selv\\s+ihjel", "ta(?:ge|ger|r)?\\s+(?:jeg\\s+)?mitt?\\s+eget\\s+liv",
        "(?:jeg\\s+(?:skal|vil|kommer\\s+til\\s+[åa]|har\\s+(?:pr[øo]vd|fors[øo]kt)\\s+[åa]|pr[øo]vde\\s+[åa]|fors[øo]kte\\s+[åa]|tenker\\s+[åa]|planlegger\\s+[åa])|(?:skal|vil)\\s+jeg)"
            + "\\s+ta\\s+livet\\s+(?:av\\s+meg|mitt)", "(?:jeg\\s+tar|tar\\s+jeg)\\s+livet\\s+(?:av\\s+meg|mitt)",
        "(?:ville\\s+)?[øo]nske,?\\s+(?:at\\s+)?jeg\\s+var\\s+d[øo]d", "(?:vil|ville)\\s+(?:hellere|heller)\\s+v[æa]re\\s+d[øo]d",
        "(?:ikke|aldrig|aldri)\\s+v[åa](?:gne|kne)\\s+(?:op\\s+|opp\\s+)?(?:igen|igjen|mere|mer)",
        "vil\\s+ikke\\s+v[æa]re\\s+her\\s+(?:mere|mer|l[æa]ngere|lenger)",
        "(?:springer|hopper)\\s+(?:ud\\s+|ut\\s+)?(?:fra|af|utfor)\\s+(?:broen|brua|en\\s+bro|taget|taket|bygningen|altanen|balkongen)(?!\\s+(?:i|ned\\s+i|ut\\s+i)\\s+(?:vannet|vandet|sj[øo]en|havet|elva))",
        "alle\\s+(?:mine\\s+)?(?:piller|pillene|tabletter|tablettene)(?:\\s+mine)?\\s+p[åa]\\s+(?:en|[ée]n)\\s+gang",
        "afskedsbrev\\w*", "avskjedsbrev\\w*",
        "(?:samlet|samler|sparer|spart|gemmer|gemt|gjemmer|gjemt)\\s+(?:opp\\s+|op\\s+|p[åa]\\s+)?(?:\\w+\\s+)?(?:piller|pillene|tabletter|tablettene|sovepiller|sovetabletter)",
        "bedre\\s+(?:uden\\s+mig|uten\\s+meg)", "(?:er|f[øo]ler\\s+(?:mig|meg)\\s+som)\\s+(?:bare\\s+)?en\\s+byrde\\s+for",
        "(?:mit\\s+liv|livet\\s+mitt|livet)\\s+har\\s+ingen\\s+mening",
        "sk[æa]rer\\s+i\\s+mig\\s+selv", "kutter\\s+meg\\s+selv", "skader\\s+(?:mig|meg)\\s+selv\\s+med\\s+(?:vilje|vilje\\s+og\\s+vett|fuldt\\s+overl[æa]g)",
        "d[øo]delig\\s+dos(?:is|e)",
        "hvor\\s+mange\\s+(?:\\w+\\s+)?(?:piller|tabletter|sovepiller|sovetabletter)\\b[^.?!]{0,40}?(?:for\\s+(?:at|[åa])\\s+d[øo]|d[øo]delig\\w*)",
        // sv
        "(?:jag\\s+(?:ska|skall|kommer\\s+att|t[äa]nker|vill|har\\s+f[öo]rs[öo]kt(?:\\s+att)?|f[öo]rs[öo]kte(?:\\s+att)?|planerar\\s+att)|(?:ska|t[äa]nker)\\s+jag)"
            + "\\s+ta\\s+livet\\s+av\\s+mig", "(?:jag\\s+tar|tar\\s+jag)\\s+livet\\s+av\\s+mig",
        "[öo]nskar\\s+(?:att\\s+)?jag\\s+var\\s+d[öo]d", "(?:vill|skulle)\\s+hellre\\s+vara\\s+d[öo]d",
        "(?:aldrig|inte)\\s+vakna\\s+(?:upp\\s+)?(?:igen|mer)", "somna\\s+och\\s+aldrig\\s+vakna",
        "vill\\s+inte\\s+(?:vara\\s+h[äa]r|finnas)\\s+(?:l[äa]ngre|mer)",
        "hoppar\\s+(?:ut\\s+)?(?:fr[åa]n|av)\\s+(?:bron|en\\s+bro|taket|balkongen|huset)(?!\\s+(?:i|ner\\s+i)\\s+(?:vattnet|sj[öo]n|havet|[äa]lven))",
        "alla\\s+(?:mina\\s+)?(?:tabletter|piller)(?:na)?(?:\\s+mina)?\\s+p[åa]\\s+en\\s+g[åa]ng", "avskedsbrev\\w*",
        "(?:samlat|samlar|sparar|sparat|g[öo]mmer|g[öo]mt)\\s+(?:p[åa]\\s+mig\\s+)?(?:\\w+\\s+)?(?:tabletter|piller|s[öo]mntabletter)",
        "b[äa]ttre\\s+utan\\s+mig", "(?:[äa]r|k[äa]nner\\s+mig\\s+som)\\s+(?:bara\\s+)?en\\s+b[öo]rda\\s+f[öo]r", "(?:mitt\\s+liv|livet)\\s+har\\s+ingen\\s+mening",
        "sk[äa]r\\s+mig\\s+sj[äa]lv", "skadar\\s+mig\\s+sj[äa]lv\\s+(?:med\\s+flit|med\\s+avsikt|avsiktligt)",
        "d[öo]dlig\\s+dos", "hur\\s+m[åa]nga\\s+(?:\\w+\\s+)?(?:tabletter|piller|s[öo]mntabletter)\\b[^.?!]{0,40}?(?:f[öo]r\\s+att\\s+d[öo]|d[öo]dlig\\w*)",
        // fi
        "tapan\\s+itseni", "(?:toivon\\s+ett[äa]\\s+olisin|olisin\\s+mieluummin)\\s+kuollut", "enk[äa]\\s+her[äa]\\w*\\s+(?:en[äa][äa]|koskaan)",
        "en\\s+halua\\s+(?:en[äa][äa]\\s+olla\\s+(?:t[äa][äa]ll[äa]|olemassa)|olla\\s+(?:t[äa][äa]ll[äa]|olemassa)\\s+en[äa][äa])",
        "hypp[äa][äa]n\\s+(?:sillalta|katolta|parvekkeelta)", "kaikki\\s+(?:l[äa][äa]kkeeni|pillerini|tablettini)\\s+kerralla(?:an)?",
        "lopet(?:an|taa|aan)\\s+el[äa]m[äa]ni", "j[äa][äa]hyv[äa]iskirje\\w*",
        "(?:ker[äa]nnyt|ker[äa][äa]n|s[äa][äa]st[äa]n|s[äa][äa]st[äa]nyt|hamstrannut|hamstraan)\\s+(?:\\w+\\s+)?(?:l[äa][äa]kkeit[äa]|pillereit[äa]|tabletteja|unil[äa][äa]kkeit[äa])",
        "parempi\\s+ilman\\s+minua", "olen\\s+(?:vain\\s+)?taakka", "el[äa]m[äa]ll[äa]ni\\s+ei\\s+ole\\s+(?:mit[äa][äa]n\\s+)?(?:merkityst[äa]|tarkoitusta)",
        "viill[äa]n\\s+itse[äa]ni", "viiltel\\w*", "satutan\\s+itse[äa]ni\\s+(?:tahallani|tahallaan|tarkoituksella)",
        "tappava\\s+annos", "(?:kuinka\\s+monta|montako)\\s+(?:\\w+\\s+)?(?:pilleri[äa]|tablettia|unil[äa][äa]kett[äa]|l[äa][äa]kett[äa])\\b[^.?!]{0,40}?(?:kuolemaan|kuollakseen|tappaa)",
        // is
        "(?:[ée]g\\s+(?:[æa]tla\\s+a[ðd]|mun|reyndi\\s+a[ðd]|hef\\s+reynt\\s+a[ðd])|[æa]tla\\s+[ée]g\\s+a[ðd])\\s+"
            + "(?:drepa\\s+mig|hengja\\s+mig|fremja\\s+sj[áa]lfsv[íi]g|taka\\s+mitt\\s+eigi[ðd]\\s+l[íi]f|binda\\s+enda\\s+[áa]\\s+l[íi]f\\s+mitt|st[öo]kkva\\s+fram\\s+af)",
        "vildi\\s+(?:a[ðd]\\s+[ée]g\\s+v[æa]ri|frekar\\s+vera)\\s+(?:dau[ðd]ur|d[áa]in|d[áa]inn)", "aldrei\\s+vakna\\s+aftur",
        "vil\\s+ekki\\s+vera\\s+(?:h[ée]rna|h[ée]r|til)\\s+lengur", "allar\\s+t[öo]flurnar\\s+(?:m[íi]nar\\s+)?[íi]\\s+einu",
        "kve[ðd]jubr[ée]f\\w*", "(?:safna[ðd]|safna|geymt)\\s+(?:\\w+\\s+)?(?:t[öo]flum|pillum|lyfjum|svefnt[öo]flum)",
        "betur\\s+sett(?:ir|ur|ar)?\\s+[áa]n\\s+m[íi]n", "[ée]g\\s+er\\s+(?:bara\\s+)?byr[ðd]i", "l[íi]fi[ðd]\\s+(?:mitt\\s+)?hefur\\s+engan\\s+tilgang",
        "(?:sker|mei[ðd]i|ska[ðd]a)\\s+mig\\s+(?:viljandi|me[ðd]\\s+vilja)",
        "banv[æa]nn\\s+skammt\\w*", "(?:hversu|hva[ðd])\\s+(?:\\w+\\s+){0,2}(?:t[öo]flur|pillur|svefnt[öo]flur)\\b[^.?!]{0,40}?til\\s+a[ðd]\\s+deyja"
    ]

    private static let russianSelfHarmSigns: [String] = [
        "(?:убью|убить|убил|убила|убивать)\\s+себя", "себя\\s+убь[юе]\\w*",
        "лучше\\s+бы\\s+(?:я\\s+)?(?:умер|умерла|сдох|сдохла)", "лучше\\s+бы\\s+меня\\s+не\\s+было",
        "(?:уснуть|заснуть)\\s+и\\s+не\\s+проснуться", "не\\s+проснуться\\s+(?:больше|никогда)",
        "повешусь", "(?:спрыгну|прыгну|брошусь)\\s+(?:с|под)\\s+(?:моста|крыши|балкона|окна|поезд)",
        "(?:выпью|приму|проглочу)\\s+все\\s+(?:свои\\s+|мои\\s+)?таблетки\\s+(?:сразу|разом)",
        "прощальн\\w+\\s+(?:записк|письм)\\w*",
        "(?:коплю|копила|копил|собираю|собрал|собрала|накопил|накопила)\\s+(?:\\w+\\s+)?(?:таблетки|снотворное|лекарства)",
        "лучше\\s+без\\s+меня", "я\\s+(?:просто\\s+)?обуза",
        "(?:в\\s+моей\\s+)?жизни\\s+нет\\s+смысла", "жизнь\\s+не\\s+имеет\\s+смысла", "нет\\s+смысла\\s+жить",
        "не\\s+хочу\\s+(?:больше\\s+)?(?:здесь\\s+быть|быть\\s+здесь|существовать)", "больше\\s+не\\s+хочу\\s+(?:здесь\\s+быть|быть\\s+здесь|существовать)",
        "режу\\s+себя", "наношу\\s+себе\\s+(?:порезы|раны)", "режу\\s+(?:себе\\s+)?(?:руки|вены)",
        "(?:смертельн|летальн)\\w+\\s+доз\\w*",
        "сколько\\s+(?:\\w+\\s+)?(?:таблеток|снотворного|лекарств|парацетамола|инсулина)\\b[^.?!]{0,40}?(?:умереть|смертельн\\w*|убить\\s+себя)"
    ]

    static let selfHarmIntentAndSignsUnbounded: [String] = [
        // ja
        "死ぬつもり", "死ぬことにした", "命を絶つ", "命を絶と", "目が覚めなければ", "目覚めなければ", "死んだほうがまし", "死んだ方がまし",
        "(?:橋|ビル|屋上|ベランダ|マンション)から飛び降り", "薬を全部まとめて飲", "薬をまとめて飲", "遺書", "薬を(?:貯め|ため|集め)", "睡眠薬を(?:貯め|ため|集め)",
        "いないほうがいい", "いない方がいい", "いなければみんな", "生きている意味がない", "生きる意味がない", "この世にいたくない", "この世から消え",
        "腕を切っ", "手首を切", "致死量", "何錠飲めば死", "飲めば死ね",
        // ko
        "죽었으면 좋겠", "죽어버렸으면", "깨어나지 않았으면", "자고 일어나지 않았으면", "죽으려고 했", "(?:다리|옥상|건물|아파트)에서 뛰어내(?:리|릴|렸)",
        "유서", "수면제를 모으", "약을 모아", "약을 모으", "내가 없으면", "모두에게 짐", "사는 게 의미가 없", "살 이유가 없",
        "이 세상에 (?:더 이상 )?있고 싶지 않", "세상에서 사라지", "팔을 긋", "손목을 긋", "치사량", "몇 알 먹으면 죽", "얼마나 먹어야 죽",
        // zh-Hans
        "杀了自己", "杀死自己", "我(?:就|要|想|会|打算|准备)去死", "宁愿死", "宁可死", "希望自己死了", "希望我死了", "再也不醒来", "再也不要醒来", "永远不要醒来",
        "从(?:桥|楼|楼顶|天台|阳台)上?跳下去", "跳楼", "所有的药一次", "把药全吃了", "一次吃完", "遗书", "攒(?:安眠药|药)", "存药", "囤(?:安眠药|药)",
        "没有我(?:大家|他们|你们)?(?:会|都会)更好", "我是(?:大家|所有人|家人)的负担", "我是个负担", "不想(?:再)?(?:待|活)在这个世界上", "不想再存在",
        "割自己", "割腕", "故意伤害自己", "致死量", "吃多少(?:片)?(?:安眠药|药)(?:会|能|才能)死",
        // ar
        "أتمنى لو كنت ميت", "اتمنى لو كنت ميت", "ليتني مت", "ليتني ميت", "أنام ولا أستيقظ", "انام ولا استيقظ",
        "أقفز من (?:فوق )?(?:الجسر|المبنى|السطح|الشرفة)", "اقفز من (?:فوق )?(?:الجسر|المبنى|السطح|الشرفة)", "كل حبوبي", "كل الحبوب مرة واحدة",
        "رسالة وداع", "أخزن الحبوب", "اخزن الحبوب", "أخبئ الحبوب", "اخبئ الحبوب", "أفضل بدوني", "افضل بدوني", "أنا عبء", "انا عبء",
        "لا معنى لحياتي", "حياتي لا معنى لها", "أن أكون هنا بعد الآن", "ان اكون هنا بعد الان", "أريد أن أكون موجود", "اريد ان اكون موجود",
        "أجرح نفسي", "اجرح نفسي", "الجرعة القاتلة", "جرعة قاتلة", "كم حبة[^.?!؟]{0,20}(?:تقتل|لأموت|لاموت|للموت)"
    ]
}
