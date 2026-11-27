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
