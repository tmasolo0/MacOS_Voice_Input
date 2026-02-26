import Testing
@testable import Solo_STT

@Suite("TextProcessingService Tests")
struct TextProcessingServiceTests {

    let sut = TextProcessingService()

    // MARK: - Empty / Whitespace Input

    @Test("Empty string returns empty")
    func emptyStringReturnsEmpty() {
        #expect(sut.process("") == "")
    }

    @Test("Whitespace-only returns empty")
    func whitespaceOnlyReturnsEmpty() {
        #expect(sut.process("   ") == "")
    }

    // MARK: - Russian Filler Removal

    @Test("Removes Russian fillers: ну, типа")
    func removesRussianFillers() {
        #expect(sut.process("ну типа привет как дела") == "Привет как дела.")
    }

    @Test("Removes Russian multi-word filler: как бы")
    func removesRussianMultiWordFillers() {
        #expect(sut.process("Привет. ну как бы нормально") == "Привет. Нормально.")
    }

    @Test("Removes Russian filler with comma: э")
    func removesRussianFillerWithComma() {
        #expect(sut.process("это, э, хороший день") == "Это, хороший день.")
    }

    @Test("Filler-only input returns empty")
    func fillerOnlyInputReturnsEmpty() {
        #expect(sut.process("ну") == "")
    }

    @Test("Removes Russian filler: то есть")
    func removesRussianFillerToEst() {
        #expect(sut.process("то есть мы идем домой") == "Мы идем домой.")
    }

    @Test("Removes Russian filler: значит")
    func removesRussianFillerZnachit() {
        #expect(sut.process("значит это так") == "Это так.")
    }

    @Test("Removes Russian filler: короче")
    func removesRussianFillerKoroche() {
        #expect(sut.process("короче давай") == "Давай.")
    }

    @Test("Removes Russian filler: вот")
    func removesRussianFillerVot() {
        #expect(sut.process("вот такие дела") == "Такие дела.")
    }

    @Test("Removes Russian filler: эм")
    func removesRussianFillerEm() {
        #expect(sut.process("эм подожди") == "Подожди.")
    }

    // MARK: - English Filler Removal

    @Test("Removes English fillers: um, so, basically")
    func removesEnglishFillers() {
        #expect(sut.process("um so basically hello") == "Hello.")
    }

    @Test("Removes English filler: you know")
    func removesEnglishYouKnow() {
        #expect(sut.process("you know it works") == "It works.")
    }

    @Test("Removes English filler: I mean")
    func removesEnglishIMean() {
        #expect(sut.process("I mean it is fine") == "It is fine.")
    }

    @Test("Removes English filler: uh")
    func removesEnglishUh() {
        #expect(sut.process("uh wait a moment") == "Wait a moment.")
    }

    @Test("Removes English filler: erm")
    func removesEnglishErm() {
        #expect(sut.process("erm let me think") == "Let me think.")
    }

    // MARK: - Context-Dependent Fillers

    @Test("'like' NOT removed in context: I like cats")
    func likeNotRemovedInContext() {
        #expect(sut.process("I like cats") == "I like cats.")
    }

    @Test("'like' removed at sentence start")
    func likeRemovedAtSentenceStart() {
        #expect(sut.process("like what are you doing") == "What are you doing.")
    }

    @Test("'so' NOT removed in context: so much")
    func soNotRemovedInContext() {
        #expect(sut.process("there is so much to do") == "There is so much to do.")
    }

    @Test("'so' removed at sentence start")
    func soRemovedAtSentenceStart() {
        #expect(sut.process("so let us begin") == "Let us begin.")
    }

    // MARK: - Capitalization

    @Test("Capitalizes first character")
    func capitalizesFirstCharacter() {
        #expect(sut.process("hello world") == "Hello world.")
    }

    @Test("Capitalizes after period")
    func capitalizesAfterPeriod() {
        #expect(sut.process("hello. world") == "Hello. World.")
    }

    @Test("Capitalizes after exclamation mark")
    func capitalizesAfterExclamation() {
        #expect(sut.process("wow! great") == "Wow! Great.")
    }

    @Test("Capitalizes after question mark")
    func capitalizesAfterQuestion() {
        #expect(sut.process("really? yes") == "Really? Yes.")
    }

    @Test("Capitalizes Russian after period")
    func capitalizesRussianAfterPeriod() {
        #expect(sut.process("привет. мир") == "Привет. Мир.")
    }

    // MARK: - Punctuation

    @Test("Adds period if missing")
    func addsPeriodIfMissing() {
        #expect(sut.process("hello world") == "Hello world.")
    }

    @Test("Does not add period if already present")
    func doesNotAddPeriodIfPresent() {
        #expect(sut.process("Hello world.") == "Hello world.")
    }

    @Test("Does not add period after exclamation")
    func doesNotAddPeriodAfterExclamation() {
        #expect(sut.process("Hello world!") == "Hello world!")
    }

    @Test("Does not add period after question mark")
    func doesNotAddPeriodAfterQuestion() {
        #expect(sut.process("Hello world?") == "Hello world?")
    }

    @Test("Collapses double spaces")
    func collapsesDoubleSpaces() {
        #expect(sut.process("hello  world") == "Hello world.")
    }

    @Test("Removes space before period")
    func removesSpaceBeforePeriod() {
        #expect(sut.process("hello .") == "Hello.")
    }

    @Test("Removes space before comma")
    func removesSpaceBeforeComma() {
        #expect(sut.process("hello , world") == "Hello, world.")
    }

    // MARK: - Idempotency

    @Test("Already correct text unchanged")
    func alreadyCorrectTextUnchanged() {
        #expect(sut.process("Hello world.") == "Hello world.")
    }

    @Test("Already correct text with exclamation")
    func alreadyCorrectWithExclamation() {
        #expect(sut.process("Great job!") == "Great job!")
    }

    // MARK: - Single Word

    @Test("Single word: capitalized with period")
    func singleWordCapitalizedWithPeriod() {
        #expect(sut.process("hello") == "Hello.")
    }

    // MARK: - Mixed Scenarios

    @Test("Multiple Russian fillers in one sentence")
    func multipleRussianFillersInSentence() {
        #expect(sut.process("ну э значит давай") == "Давай.")
    }

    @Test("Filler between sentences")
    func fillerBetweenSentences() {
        #expect(sut.process("Хорошо. ну ладно") == "Хорошо. Ладно.")
    }

    @Test("Multiple English fillers removed")
    func multipleEnglishFillersRemoved() {
        #expect(sut.process("um uh basically yes") == "Yes.")
    }
}
