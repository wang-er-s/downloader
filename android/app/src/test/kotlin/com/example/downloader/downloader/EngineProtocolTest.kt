package com.example.downloader.downloader

import org.junit.Assert.*
import org.junit.Test

class EngineProtocolTest {
    private fun command() =
        mapOf<String, Any?>(
            "protocolVersion" to 1,
            "commandId" to "c",
            "taskId" to "t",
            "engineId" to "e",
            "generation" to 0L,
            "ownerSessionId" to "s",
            "expectedReceiptVersion" to 0,
        )

    private fun rejects(
        reason: String = "invalidPayload",
        action: () -> Unit,
    ) {
        try {
            action()
            fail("accepted invalid payload")
        } catch (error: EngineProtocolException) {
            assertEquals(reason, error.reason)
        }
    }

    @Test fun handshakeAndCodecIntegerWidths() {
        assertEquals(1L, EngineProtocol.number(EngineProtocol.request(mapOf("protocolVersion" to 1L)), "protocolVersion"))
        assertEquals(ExecutionKey("t", "e", 0), EngineProtocol.command("pause", command()).key)
        assertEquals(
            Long.MAX_VALUE,
            EngineProtocol.command("pause", command() + ("expectedReceiptVersion" to Long.MAX_VALUE)).expectedReceiptVersion,
        )
    }

    @Test fun rejectsVersionTypesMissingFieldsAndRanges() {
        for (value in listOf(null, true, "1", 1.0, 2, -1)) {
            rejects {
                EngineProtocol.request(mapOf("protocolVersion" to value))
            }
        }
        for (field in listOf("commandId", "taskId", "engineId", "ownerSessionId")) {
            for (value in listOf(null, "", " ", "id\u0000", "id\u007f", "id\u0085", 3, false)) {
                rejects {
                    EngineProtocol.command("pause", command() + (field to value))
                }
            }
        }
        for (field in listOf("generation", "expectedReceiptVersion")) {
            for (value in listOf(null, "0", 0.0, -1L, false)) {
                rejects {
                    EngineProtocol.command("pause", command() + (field to value))
                }
            }
        }
    }

    @Test fun ackRequiresCompleteIdentityAndTypedReleaseList() {
        val ack = command() + mapOf("receiptVersion" to 3L, "releaseResumeRefs" to emptyList<String>())
        assertEquals(3L, EngineProtocol.ack(ack).receiptVersion)
        rejects { EngineProtocol.ack(ack + ("receiptVersion" to 0)) }
        rejects { EngineProtocol.ack(ack + ("releaseResumeRefs" to listOf(1))) }
        rejects { EngineProtocol.ack(ack - "taskId") }
    }

    @Test fun enqueueChecksNestedIdentityUrlAndAndroidDirectory() {
        val input =
            mapOf(
                "protocolVersion" to 1,
                "key" to ExecutionKey("t", "e", 0).json(),
                "url" to "https://example.test/a",
                "stagingLocation" to "/private/staging",
                "directory" to mapOf("version" to 1, "platform" to "android", "kind" to "systemDownloads", "displayName" to "Downloads"),
            )
        EngineProtocol.command("enqueue", command() + ("input" to input))
        for (name in listOf("file.", "file ", "CON", "nul.txt", "Lpt9.log", "file\u007f")) {
            rejects {
                EngineProtocol.command("enqueue", command() + ("input" to (input + ("requestedFileName" to name))))
            }
            rejects {
                val directory = EngineProtocol.map(input["directory"]) + ("subdirectory" to name)
                EngineProtocol.command("enqueue", command() + ("input" to (input + ("directory" to directory))))
            }
        }
        rejects("staleExecution") {
            EngineProtocol.command(
                "enqueue",
                command() + ("input" to (input + ("key" to ExecutionKey("other", "e", 0).json()))),
            )
        }
        for (url in listOf("file:///tmp/a", "https://u:p@example.test/a", "http:///missing")) {
            rejects {
                EngineProtocol.command("enqueue", command() + ("input" to (input + ("url" to url))))
            }
        }
    }

    @Test fun checkpointPreservesUnknownTotalAnd64BitBytes() {
        val receipt = NativeCheckpoint("paused", 5_000_000_000).receipt(ExecutionKey("t", "e", 0), 1)
        assertEquals(5_000_000_000L, receipt["downloadedBytes"])
        assertNull(receipt["totalBytes"])
        try {
            NativeCheckpoint("completed", 0)
            fail("synthetic completion accepted")
        } catch (_: IllegalArgumentException) {
        }
    }
}
