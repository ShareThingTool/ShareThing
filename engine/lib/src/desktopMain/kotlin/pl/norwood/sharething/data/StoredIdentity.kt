package pl.norwood.sharething.data

import kotlinx.serialization.Serializable

@Serializable
data class StoredIdentity(
    val privateKey: String
)