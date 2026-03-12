package org.mcduck.pritupir.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun ProgressBar(
    fileName: String,
    progress: Float,
    eta: String
) {
    Column {
        Text("Downloading: $fileName")

        LinearProgressIndicator(
            progress = progress,
            modifier = Modifier.fillMaxWidth()
        )

        Text("ETA: $eta")
    }
}