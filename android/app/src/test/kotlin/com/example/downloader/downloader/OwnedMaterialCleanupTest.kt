package com.example.downloader.downloader

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.UUID

class OwnedMaterialCleanupTest {
    private fun pair(root: File): OwnedMaterialCleanup.Pair {
        val dir = File(root, "http_staging_v1").apply { mkdirs() }
        val id = UUID.randomUUID().toString()
        val part = File(dir, "$id.part").apply { writeText("payload") }
        val facts = File(dir, "$id.facts").apply { writeText("facts") }
        return OwnedMaterialCleanup.Pair(part.path, facts.path)
    }

    @Test fun lastInvalidMemberPreventsEveryDelete() {
        val root = Files.createTempDirectory("cleanup").toFile().canonicalFile
        try {
            val first = pair(root)
            val last = pair(root)
            for (bad in listOf(last.copy(facts = File(root, "outside").path), last)) {
                if (bad ==
                    last
                ) {
                    File(last.facts).delete()
                    Files.createSymbolicLink(File(last.facts).toPath(), File(first.facts).toPath())
                }
                try {
                    OwnedMaterialCleanup(root).run(listOf(first, bad), {})
                    fail("unsafe collection")
                } catch (
                    _: EngineProtocolException,
                ) {
                }
                assertTrue(File(first.payload).exists())
                assertTrue(File(first.facts).exists())
                assertTrue(File(last.payload).exists())
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun partialDeletionAndMissingFilesResumeIdempotently() {
        val root = Files.createTempDirectory("cleanup").toFile().canonicalFile
        try {
            val members = listOf(pair(root), pair(root))
            val done = mutableListOf<String>()
            var count = 0
            try {
                OwnedMaterialCleanup(root).run(members, { done.add(it) }, { file ->
                    if (++count == 3) throw java.io.IOException("injected delete fault")
                    Files.deleteIfExists(file.toPath())
                })
                fail("IO must propagate")
            } catch (_: java.io.IOException) {
            }
            assertEquals(2, done.size)
            assertTrue(File(members.last().payload).exists())
            OwnedMaterialCleanup(root).run(members, { done.add(it) })
            assertTrue(members.all { !File(it.payload).exists() && !File(it.facts).exists() })
            OwnedMaterialCleanup(root).run(members, {})
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun directorySymlinkAndNonRegularMemberRejectWithoutDeleting() {
        val root = Files.createTempDirectory("cleanup").toFile().canonicalFile
        val outside = Files.createTempDirectory("sentinel").toFile().canonicalFile
        try {
            val external = pair(outside)
            Files.createSymbolicLink(File(root, "http_staging_v1").toPath(), File(outside, "http_staging_v1").toPath())
            val member =
                OwnedMaterialCleanup.Pair(
                    File(root, "http_staging_v1/${File(external.payload).name}").path,
                    File(root, "http_staging_v1/${File(external.facts).name}").path,
                )
            try {
                OwnedMaterialCleanup(root).run(listOf(member), {})
                fail("directory symlink")
            } catch (_: EngineProtocolException) {
            }
            assertEquals("payload", File(external.payload).readText())
            Files.delete(File(root, "http_staging_v1").toPath())
            val regular = pair(root)
            File(regular.facts).delete()
            File(regular.facts).mkdir()
            try {
                OwnedMaterialCleanup(root).run(listOf(regular), {})
                fail("non regular")
            } catch (_: EngineProtocolException) {
            }
            assertTrue(File(regular.payload).exists())
        } finally {
            root.deleteRecursively()
            outside.deleteRecursively()
        }
    }
}
