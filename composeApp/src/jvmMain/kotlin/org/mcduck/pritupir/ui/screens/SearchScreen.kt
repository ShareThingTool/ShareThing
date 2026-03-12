package org.mcduck.pritupir.ui.screens

import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import org.mcduck.pritupir.ui.lang.Strings

data class SearchResult(
    val name: String,
    val type: String,
    val size: String,
    val uploader: String,
    val users: Int
)

@Composable
fun SearchScreen(strings: Strings) {
    var query by remember { mutableStateOf("") }
    val focusManager = LocalFocusManager.current

    val allItems = listOf(
        SearchResult("song.mp3", "Sound", "5 MB", "katolik666", 3),
        SearchResult("movie.mkv", "Video", "700 MB", "pawlek12", 12),
        SearchResult("document.pdf", "Document", "2 MB", "rejwer_drugi", 1),
        SearchResult("linux.iso", "Image", "3.5 GB", "donaldtux", 20),
        SearchResult("photo.png", "Photo", "800 KB", "twojstary", 2)
    )

    val filteredItems = allItems.filter {
        it.name.contains(query, ignoreCase = true)
    }

    var selectedItem by remember { mutableStateOf<SearchResult?>(null) }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions.Default.copy(
                imeAction = ImeAction.Search
            ),
            keyboardActions = KeyboardActions(
                onSearch = { focusManager.clearFocus() }
            )
        )

        Spacer(modifier = Modifier.height(16.dp))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 4.dp)
        ) {
            Text(
                text = strings.file,
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.subtitle2
            )

            Text(
                text = strings.type,
                modifier = Modifier.width(80.dp),
                style = MaterialTheme.typography.subtitle2
            )

            Text(
                text = strings.uploader,
                modifier = Modifier.width(120.dp),
                style = MaterialTheme.typography.subtitle2
            )

            Text(
                text = strings.size,
                modifier = Modifier.width(80.dp),
                style = MaterialTheme.typography.subtitle2
            )

            Text(
                text = strings.users,
                modifier = Modifier.width(40.dp),
                style = MaterialTheme.typography.subtitle2
            )
        }

        Divider()

        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
        ) {
            items(filteredItems) { item ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(8.dp)
                        .clickable { selectedItem = item }
                ) {
                    Text(
                        text = item.name,
                        modifier = Modifier.weight(1f)
                    )

                    Text(
                        text = item.type,
                        modifier = Modifier.width(80.dp)
                    )

                    Text(
                        text = item.uploader,
                        modifier = Modifier.width(120.dp)
                    )

                    Text(
                        text = item.size,
                        modifier = Modifier.width(80.dp)
                    )

                    Text(
                        text = item.users.toString(),
                        modifier = Modifier.width(40.dp)
                    )
                }
                Divider()
            }
        }
        selectedItem?.let { file ->
            Spacer(modifier = Modifier.height(8.dp))

            Card(
                elevation = 4.dp,
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(12.dp)) {
                    Text(text = file.name, style = MaterialTheme.typography.h6)
                    Text("${strings.type}: ${file.type}")
                    Text("${strings.size}: ${file.size}")
                    Text("${strings.uploader}: ${file.uploader}")
                    Text("${strings.users}: ${file.users}")

                    if (file.type == "Sound") {
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(strings.albumArt)
                    }
                }
            }
        }

    }
}
