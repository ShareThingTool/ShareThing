package pl.norwood.sharething

object EngineRuntime {
    @Volatile
    var emitEvent: (EngineEvent) -> Unit = {}

    fun emit(event: EngineEvent) {
        emitEvent(event)
    }
}
