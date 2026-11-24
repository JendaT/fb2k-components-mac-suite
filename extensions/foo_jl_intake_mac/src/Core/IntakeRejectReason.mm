//
//  IntakeRejectReason.mm
//  foo_jl_intake
//

#include "IntakeRejectReason.h"

namespace intake {

namespace {

bool isTrimmed(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

} // anonymous namespace

const std::vector<std::string> &rejectReasonChoices() {
    static const std::vector<std::string> choices = {
        "Already in library",
        "Lower quality than library copy",
        "Not wanted",
        "Other\xE2\x80\xA6",  // U+2026
    };
    return choices;
}

size_t rejectReasonOtherIndex() {
    return rejectReasonChoices().size() - 1;
}

bool rejectChoiceIsOther(size_t choice) {
    return choice >= rejectReasonOtherIndex();
}

std::string rejectReasonFor(size_t choice, const std::string &freeText) {
    if (!rejectChoiceIsOther(choice)) return rejectReasonChoices()[choice];
    size_t begin = 0;
    while (begin < freeText.size() && isTrimmed(freeText[begin])) begin++;
    size_t end = freeText.size();
    while (end > begin && isTrimmed(freeText[end - 1])) end--;
    return freeText.substr(begin, end - begin);
}

size_t rejectInitialChoice(size_t lastChoice) {
    return lastChoice < rejectReasonChoices().size() ? lastChoice : 0;
}

} // namespace intake
