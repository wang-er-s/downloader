package com.example.downloader.downloader

import java.util.UUID

/** Process-only capabilities. Only short lifecycle actions hold this monitor; never SQLite or network IO. */
internal class ServiceLifecycle {
    data class Idle(
        val epoch: Long,
        val instance: String?,
    )

    private class Grant(
        val stop: HttpTransfer.Stop,
    ) {
        var instance: String? = null
        var claimed = false
        var ready = false
    }

    private val grants = mutableMapOf<String, Grant>()
    private val retired = mutableSetOf<String>()
    private var epoch = 0L
    private var owner: String? = null

    @Synchronized fun issue(stop: HttpTransfer.Stop): String {
        if (grants.isEmpty()) epoch = Math.addExact(epoch, 1)
        val token = UUID.randomUUID().toString()
        grants[token] = Grant(stop)
        return token
    }

    /** Actual startService and foreground operations are short and guarded by the same ownership. */
    @Synchronized fun pending(
        token: String?,
        action: () -> Unit,
    ): Boolean {
        val grant = grants[token] ?: return false
        if (grant.claimed || grant.stop.reason != null) return false
        try {
            action()
        } catch (error: Exception) {
            grants.remove(token)
            throw error
        }
        return true
    }

    /** Every delivered system start owes promotion, independently of download capabilities.
     * Promotion never issues a grant. Even revoked/unknown tokens must discharge that obligation.
     */
    @Synchronized fun deliver(
        token: String?,
        instance: String,
        promote: () -> Unit,
        authorize: () -> Unit,
    ): Boolean {
        try {
            promote()
        } catch (error: Exception) {
            val grant = grants[token]
            if (grant?.instance == null) {
                grants.remove(token)?.stop?.request(HttpTransfer.Stop.Reason.PAUSE)
            } else if (grant.instance == instance) {
                // Keep the claimed grant until destroy can report all affected workers.
                grant.stop.request(HttpTransfer.Stop.Reason.PAUSE)
            }
            // A stale instance must not revoke a capability already owned elsewhere.
            throw error
        }
        return foreground(token, instance, authorize)
    }

    @Synchronized fun foreground(
        token: String?,
        instance: String,
        action: () -> Unit,
    ): Boolean {
        val grant = grants[token] ?: return false
        if (instance in retired || grant.claimed || grant.stop.reason != null) return false
        if (owner != null && owner != instance) return false
        grant.claimed = true
        grant.instance = instance
        owner = instance
        try {
            action()
        } catch (error: Exception) {
            // Revoke before a potentially blocked journal queue can observe this failed start.
            grants.remove(token)
            throw error
        }
        return true
    }

    /** Called on the coordinator queue, after the foreground operation actually succeeded. */
    @Synchronized fun ready(
        token: String?,
        instance: String? = null,
    ): Boolean {
        val grant = grants[token] ?: return false
        if (grant.ready || grant.stop.reason != null) return false
        if (instance != null && (!grant.claimed || grant.instance != instance || instance in retired)) return false
        grant.ready = true
        return true
    }

    @Synchronized fun worker(
        token: String,
        action: () -> Unit,
    ): Boolean {
        val grant = grants[token] ?: return false
        if (!grant.ready || grant.stop.reason != null || grant.instance in retired) return false
        action()
        return true
    }

    @Synchronized fun revoke(token: String?) {
        grants.remove(token)
    }

    /** Immediate emergency signal, before any queued SQLite work. Only this instance's grants. */
    @Synchronized fun destroy(
        instance: String,
        action: (() -> Unit)? = null,
    ): Set<String> {
        val wasOwner = owner == instance
        retired.add(instance)
        val owned = grants.filterValues { it.instance == instance }.keys.toSet()
        owned.forEach { token -> grants.remove(token)?.stop?.request(HttpTransfer.Stop.Reason.PAUSE) }
        if (owner == instance) owner = null
        if (wasOwner) action?.invoke()
        return owned
    }

    @Synchronized fun idle(): Idle? = if (grants.isEmpty()) Idle(epoch, owner) else null

    @Synchronized fun stop(
        ticket: Idle,
        action: (String) -> Unit,
    ): Boolean {
        val instance = ticket.instance ?: return false
        if (grants.isNotEmpty() || epoch != ticket.epoch || owner != instance) return false
        retired.add(instance)
        owner = null
        action(instance)
        return true
    }

    /** A delayed failure from an old instance cannot fail another instance before ready. */
    @Synchronized fun acceptsFailure(token: String?, instance: String): Boolean =
        grants[token]?.instance.let { it == null || it == instance }

    @Synchronized fun unclaimed(token: String?): Boolean = grants[token]?.claimed == false

    @Synchronized fun stopUnowned(
        instance: String,
        action: () -> Unit,
    ) {
        if (owner != instance && grants.values.none { it.instance == instance }) action()
    }

    @Synchronized fun owns(instance: String): Boolean = owner == instance && instance !in retired
}
