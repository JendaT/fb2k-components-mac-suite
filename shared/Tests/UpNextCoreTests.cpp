#include "TestHarness.h"
#include "../UpNextCore.h"

using namespace upnext;

static PlaybackState fromNP(bool shuffle = false) {
    PlaybackState s;
    s.playing = true; s.playingFromNowPlaying = true;
    s.playingIndex = 3; s.playingPlaylistCount = 10; s.nowPlayingCount = 10;
    s.shuffle = shuffle;
    return s;
}
static PlaybackState fromOther() {
    PlaybackState s;
    s.playing = true; s.playingFromNowPlaying = false;
    s.playingIndex = 5; s.playingPlaylistCount = 12; s.nowPlayingCount = 3;
    return s;
}

int main() {
    g_context = "planEdit NP";
    { EditPlan p = planEdit(Action::PlayNext, fromNP());
      CHECK(!p.copyRemainder, "no copy"); CHECK_EQ(p.insertAt, 4, "insertAt");
      CHECK(!p.useFoobarQueue, "no queue"); CHECK(!p.switchPlayingToNowPlaying, "no switch"); }
    { EditPlan p = planEdit(Action::AddToQueue, fromNP()); CHECK_EQ(p.insertAt, 10, "append"); }
    { EditPlan p = planEdit(Action::PlayNext, fromNP(true)); CHECK(p.useFoobarQueue, "shuffle queue"); }
    { EditPlan p = planEdit(Action::AddToQueue, fromNP(true));
      CHECK(!p.useFoobarQueue, "no queue"); CHECK_EQ(p.insertAt, 10, "append"); }

    g_context = "planEdit other";
    { EditPlan p = planEdit(Action::PlayNext, fromOther());
      CHECK(p.copyRemainder, "copy"); CHECK_EQ(p.copyFrom, 5, "from");
      CHECK(p.switchPlayingToNowPlaying, "switch"); CHECK_EQ(p.insertAt, 1, "insertAt"); }
    { EditPlan p = planEdit(Action::AddToQueue, fromOther()); CHECK_EQ(p.insertAt, 7, "append"); }

    g_context = "planEdit stopped";
    { PlaybackState s; s.nowPlayingCount = 4; s.nowPlayingFocus = 2;
      EditPlan p = planEdit(Action::PlayNext, s);
      CHECK_EQ(p.insertAt, 3, "after focus"); CHECK(!p.copyRemainder, "no copy");
      p = planEdit(Action::AddToQueue, s);
      CHECK_EQ(p.insertAt, 4, "append"); CHECK(!p.copyRemainder, "no copy");
      s.nowPlayingFocus.reset();
      p = planEdit(Action::PlayNext, s);
      CHECK_EQ(p.insertAt, 0, "no focus"); CHECK(!p.copyRemainder, "no copy");
      CHECK(p.focusFirstInserted, "stopped focuses inserted");
      p = planEdit(Action::AddToQueue, s); CHECK(p.focusFirstInserted, "stopped focuses inserted (queue)"); }
    { PlaybackState s; // empty / missing Now Playing
      EditPlan p = planEdit(Action::AddToQueue, s);
      CHECK_EQ(p.insertAt, 0, "empty NP"); CHECK(p.focusFirstInserted, "empty NP focus"); }
    CHECK(!planEdit(Action::AddToQueue, fromNP()).focusFirstInserted, "playing: no focus move");
    CHECK(!planEdit(Action::PlayNext, fromOther()).focusFirstInserted, "playing other: no focus move");

    g_context = "stoppedStartIndex";
    CHECK(!stoppedStartIndex(0, std::nullopt), "empty");
    CHECK(!stoppedStartIndex(0, 3), "empty with focus");
    CHECK(*stoppedStartIndex(5, 3) == 3, "focus");
    CHECK(*stoppedStartIndex(5, std::nullopt) == 0, "no focus");
    CHECK(*stoppedStartIndex(5, 9) == 0, "stale focus");

    g_context = "planQueueRestore";
    {   // Shuffle Play Next: X at np[4] and queued (np,4); playing X must not re-queue it.
        std::vector<SavedQueueEntry> saved = { {0, 4, 0xA, true}, {0, 7, 0xB, true} };
        auto ops = planQueueRestore(saved, 0, 4, {});
        CHECK_EQ(ops.size(), 1, "started skipped");
        CHECK(ops.size() == 1 && ops[0].savedIndex == 1 && ops[0].byLocation, "other kept");
    }
    {   // Only the FIRST matching entry is consumed.
        std::vector<SavedQueueEntry> saved = { {0, 4, 0xA, true}, {0, 4, 0xA, true} };
        auto ops = planQueueRestore(saved, 0, 4, {});
        CHECK(ops.size() == 1 && ops[0].savedIndex == 1, "second duplicate kept");
    }
    {   // Invalid location never matches the started item; restored by handle.
        std::vector<SavedQueueEntry> saved = { {0, 4, 0xA, false} };
        auto ops = planQueueRestore(saved, 0, 4, {});
        CHECK(ops.size() == 1 && !ops[0].byLocation, "by handle");
    }
    {   // No flush happened: everything is still queued -> nothing re-added.
        std::vector<SavedQueueEntry> saved = { {1, 2, 0xA, true}, {kNoIndex, kNoIndex, 0xB, false} };
        std::vector<LiveQueueEntry> live = { {1, 2, 0xA}, {kNoIndex, kNoIndex, 0xB} };
        CHECK(planQueueRestore(saved, 3, 0, live).empty(), "already present");
    }
    {   // Partially present; each live entry matches once.
        std::vector<SavedQueueEntry> saved = { {1, 2, 0xA, true}, {1, 2, 0xA, true}, {1, 5, 0xC, false} };
        std::vector<LiveQueueEntry> live = { {1, 2, 0xA}, {kNoIndex, kNoIndex, 0xC} };
        auto ops = planQueueRestore(saved, kNoIndex, kNoIndex, live);
        CHECK(ops.size() == 1 && ops[0].savedIndex == 1, "one copy restored");
    }
    {   // By-location live entry with same handle does not satisfy a different slot.
        std::vector<SavedQueueEntry> saved = { {1, 2, 0xA, true} };
        std::vector<LiveQueueEntry> live = { {1, 3, 0xA} };
        CHECK_EQ(planQueueRestore(saved, kNoIndex, kNoIndex, live).size(), 1, "different slot");
    }
    {   // Unknown started item: nothing skipped.
        std::vector<SavedQueueEntry> saved = { {0, 4, 0xA, true} };
        CHECK_EQ(planQueueRestore(saved, kNoIndex, kNoIndex, {}).size(), 1, "no skip");
    }

    g_context = "addedFeedbackText";
    CHECK(addedFeedbackText(12, false) == "Added 12 tracks to queue", "queue plural");
    CHECK(addedFeedbackText(1, false) == "Added 1 track to queue", "queue singular");
    CHECK(addedFeedbackText(3, true) == "Playing 3 tracks next", "next plural");
    CHECK(addedFeedbackText(1, true) == "Playing 1 track next", "next singular");

    g_context = "unknown playing index";
    { PlaybackState s = fromNP(); s.playingIndexKnown = false; s.nowPlayingFocus = 7;
      EditPlan p = planEdit(Action::PlayNext, s);
      CHECK_EQ(p.insertAt, 0, "front, not focus"); CHECK(!p.copyRemainder, "no copy");
      p = planEdit(Action::AddToQueue, s); CHECK_EQ(p.insertAt, 10, "append"); }
    { auto r = resolvePlayingIndex(true, 4, 9); CHECK(r && *r == 4, "location wins"); }
    { auto r = resolvePlayingIndex(false, 0, 9); CHECK(r && *r == 9, "found"); }
    { auto r = resolvePlayingIndex(false, 0, std::nullopt); CHECK(!r, "unknown"); }

    g_context = "isShuffleOrderName";
    CHECK(!isShuffleOrderName("Default"), "Default");
    CHECK(!isShuffleOrderName("Repeat (playlist)"), "Repeat playlist");
    CHECK(!isShuffleOrderName("repeat (TRACK)"), "repeat track");
    CHECK(isShuffleOrderName("Shuffle (tracks)"), "tracks");
    CHECK(isShuffleOrderName("Shuffle (albums)"), "albums");
    CHECK(isShuffleOrderName("Shuffle (folders)"), "folders");
    CHECK(isShuffleOrderName("Random"), "random");

    g_context = "buildSections";
    { auto r = buildSections(true, 2, 5);
      CHECK(r.showCurrent && r.nextFrom == 3 && r.nextCount == 2, "mid"); }
    { auto r = buildSections(true, 4, 5);
      CHECK(r.showCurrent && r.nextFrom == 5 && r.nextCount == 0, "last"); }
    { auto r = buildSections(false, 0, 4);
      CHECK(!r.showCurrent && r.nextFrom == 0 && r.nextCount == 4, "stopped"); }
    { auto r = buildSections(false, 0, 0);
      CHECK(!r.showCurrent && r.nextFrom == 0 && r.nextCount == 0, "empty"); }

    g_context = "isDuplicateFoobarMenuItem";
    CHECK(isDuplicateFoobarMenuItem("Play"), "Play");
    CHECK(isDuplicateFoobarMenuItem(" play "), "padded");
    CHECK(isDuplicateFoobarMenuItem("Add to playback queue"), "queue");
    CHECK(isDuplicateFoobarMenuItem("Add to Playback Queue"), "Queue");
    CHECK(!isDuplicateFoobarMenuItem("Play Next"), "Play Next");
    CHECK(!isDuplicateFoobarMenuItem("Add to Queue"), "Add to Queue");
    CHECK(!isDuplicateFoobarMenuItem("Playback Statistics"), "Stats");

    TEST_MAIN_END();
}
