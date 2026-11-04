package com.example.downloader.downloader

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS

/** Only journal-snapshotted pairs may enter here. Validate the entire set before any IO mutation. */
internal class OwnedMaterialCleanup(
    private val root: File,
) {
    data class Pair(
        val payload: String,
        val facts: String,
    )

    fun run(
        pairs: List<Pair>,
        deleted: (String) -> Unit,
        remove: (File) -> Unit = { Files.deleteIfExists(it.toPath()) },
    ) {
        val directory = File(root, "http_staging_v1")
        if (root != root.canonicalFile || !root.isDirectory || Files.isSymbolicLink(root.toPath()) ||
            directory != directory.canonicalFile || Files.isSymbolicLink(directory.toPath()) ||
            (Files.exists(directory.toPath(), NOFOLLOW_LINKS) && !Files.isDirectory(directory.toPath(), NOFOLLOW_LINKS))
        ) {
            conflict("materialOwnership")
        }
        val members =
            pairs.flatMap { pair ->
                val payload = File(pair.payload)
                val facts = File(pair.facts)
                val id = payload.name.removeSuffix(".part")
                if (!id.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")) ||
                    payload.name != "$id.part" || facts.name != "$id.facts"
                ) {
                    conflict("materialOwnership")
                }
                listOf(payload, facts).onEach { file ->
                    if (file.parentFile != directory || file != file.absoluteFile || file != file.canonicalFile ||
                        Files.isSymbolicLink(file.toPath()) ||
                        (Files.exists(file.toPath(), NOFOLLOW_LINKS) && !Files.isRegularFile(file.toPath(), NOFOLLOW_LINKS))
                    ) {
                        conflict("materialOwnership")
                    }
                }
            }
        if (members.map { it.path }.distinct().size != members.size) conflict("materialOwnership")
        for (file in members) {
            // Missing registered files are idempotent, including a crash after delete but before done.
            remove(file)
            deleted(file.path)
        }
    }
}
