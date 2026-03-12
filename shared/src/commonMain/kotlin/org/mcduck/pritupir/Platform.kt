package org.mcduck.pritupir

interface Platform {
    val name: String
}

expect fun getPlatform(): Platform