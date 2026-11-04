package com.example.downloader.downloader

import org.junit.Assert.*
import org.junit.Test

/** Exercises the same ownership object used around actual Android actions in production. */
class ServiceLifecycleTest {
    @Test fun failedStartServiceRevokesBeforeDelayedFailureCallback() {
        val lifecycle = ServiceLifecycle()
        val token = lifecycle.issue(HttpTransfer.Stop())
        val failure = IllegalStateException("background start rejected")
        try {
            lifecycle.pending(token) { throw failure }
            fail("must throw")
        } catch (error: IllegalStateException) { assertSame(failure, error) }
        assertFalse(lifecycle.foreground(token, "late-service") { fail("failed start authorized foreground") })
        assertFalse(lifecycle.ready(token, "late-service"))
        assertFalse(lifecycle.worker(token) { fail("failed start authorized worker") })
    }

    @Test fun failedForegroundRevokesBeforeAnyJournalCallbackAndIdleCannotStopNextEpoch() {
        val lifecycle = ServiceLifecycle()
        val token = lifecycle.issue(HttpTransfer.Stop())
        val failure = SecurityException("denied")
        try {
            lifecycle.foreground(token, "service") { throw failure }
            fail("must throw")
        } catch (error: SecurityException) { assertSame(failure, error) }
        assertFalse(lifecycle.ready(token, "service"))
        assertFalse(lifecycle.worker(token) { fail("failed foreground authorized worker") })
        val idle = lifecycle.idle()!!
        val next = lifecycle.issue(HttpTransfer.Stop())
        assertFalse(lifecycle.stop(idle) { fail("failed start stopped later command") })
        assertTrue(lifecycle.foreground(next, "service") {})
        assertTrue(lifecycle.ready(next, "service"))
    }

    @Test fun instanceTimeoutRetiresEveryStartAndNeverStopsLaterInstance() {
        val lifecycle = ServiceLifecycle()
        val firstStop = HttpTransfer.Stop()
        val secondStop = HttpTransfer.Stop()
        val first = lifecycle.issue(firstStop)
        val second = lifecycle.issue(secondStop)
        assertTrue(lifecycle.foreground(first, "old") {})
        assertTrue(lifecycle.foreground(second, "old") {})
        var stopCalls = 0
        assertEquals(setOf(first, second), lifecycle.destroy("old") { stopCalls++ })
        assertEquals(1, stopCalls)
        assertEquals(HttpTransfer.Stop.Reason.PAUSE, firstStop.reason)
        assertEquals(HttpTransfer.Stop.Reason.PAUSE, secondStop.reason)
        val fresh = lifecycle.issue(HttpTransfer.Stop())
        assertTrue(lifecycle.foreground(fresh, "new") {})
        lifecycle.destroy("old") { fail("old timeout stopped new instance") }
        assertTrue(lifecycle.ready(fresh, "new"))
    }

    @Test fun oldIdleAndDestroyCannotStopNewInstanceOrPendingLaunch() {
        val lifecycle = ServiceLifecycle()
        val oldStop = HttpTransfer.Stop()
        val old = lifecycle.issue(oldStop)
        assertTrue(lifecycle.foreground(old, "old") {})
        assertTrue(lifecycle.ready(old, "old"))
        lifecycle.revoke(old)
        val idlePost = lifecycle.idle()!!
        val nextStop = HttpTransfer.Stop()
        val next = lifecycle.issue(nextStop)
        assertFalse(lifecycle.stop(idlePost) { fail("old idle stopped new enqueue") })
        assertTrue(lifecycle.destroy("old").isEmpty())
        assertTrue(lifecycle.foreground(next, "new") {})
        assertTrue(lifecycle.ready(next, "new"))
        assertTrue(lifecycle.destroy("old").isEmpty())
        assertNull(nextStop.reason)
        var runs = 0
        assertTrue(lifecycle.worker(next) { runs++ })
        assertEquals(1, runs)
        assertFalse(lifecycle.foreground(old, "old") { fail("replayed token") })
        assertFalse(ServiceLifecycle().foreground(next, "new-process") { fail("old process token") })
    }

    @Test fun cancelBetweenPostedStartAndForegroundInvalidatesCapability() {
        val lifecycle = ServiceLifecycle()
        val stop = HttpTransfer.Stop()
        val token = lifecycle.issue(stop)
        var posted: (() -> Unit)? = null
        assertTrue(
            lifecycle.pending(token) {
                posted = {
                    lifecycle.foreground(token, "service") { fail("cancelled foreground") }
                    Unit
                }
            },
        )
        lifecycle.revoke(token)
        stop.request(HttpTransfer.Stop.Reason.CANCEL)
        posted!!()
        assertFalse(lifecycle.ready(token, "service"))
        assertFalse(lifecycle.worker(token) { fail("cancelled worker") })
    }

    @Test fun timeoutAfterForegroundBeforeReadySignalsImmediatelyAndOnlyOwnedWork() {
        val lifecycle = ServiceLifecycle()
        val stop = HttpTransfer.Stop()
        val token = lifecycle.issue(stop)
        assertTrue(lifecycle.foreground(token, "old") {})
        assertEquals(setOf(token), lifecycle.destroy("old"))
        assertEquals(HttpTransfer.Stop.Reason.PAUSE, stop.reason)
        assertFalse(lifecycle.ready(token, "old"))
        assertFalse(lifecycle.worker(token) { fail("timeout worker") })
        val newStop = HttpTransfer.Stop()
        val fresh = lifecycle.issue(newStop)
        assertTrue(lifecycle.foreground(fresh, "new") {})
        assertTrue(lifecycle.ready(fresh, "new"))
        lifecycle.destroy("old") { fail("old timeout stopped new instance") }
        assertNull(newStop.reason)
        assertTrue(lifecycle.worker(fresh) {})
    }

    @Test fun committedIdleStopsOnlyItsOwnerAndOldCallbacksCannotClaimNewEpoch() {
        val lifecycle = ServiceLifecycle()
        val first = lifecycle.issue(HttpTransfer.Stop())
        assertTrue(lifecycle.foreground(first, "old") {})
        lifecycle.revoke(first)
        var stopped: String? = null
        assertTrue(lifecycle.stop(lifecycle.idle()!!) { stopped = it })
        assertEquals("old", stopped)
        val next = lifecycle.issue(HttpTransfer.Stop())
        assertFalse(lifecycle.foreground(next, "old") { fail("retired instance") })
        assertTrue(lifecycle.foreground(next, "new") {})
        assertFalse(lifecycle.foreground(next, "new") { fail("duplicate foreground") })
        assertTrue(lifecycle.ready(next, "new"))
        assertFalse(lifecycle.ready(next, "new"))
    }
}
