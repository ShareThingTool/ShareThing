package org.mcduck.pritupir.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

import org.mcduck.pritupir.ui.lang.Strings

@Composable
fun SettingsScreen(
    strings: Strings,
    selectedLanguage: String,
    onLanguageChange: (String) -> Unit,
    owoEnabled: Boolean,
    onOwOChange: (Boolean) -> Unit
) {
    val languages = listOf(strings.english, strings.polish)

    var expanded by remember { mutableStateOf(false) }

    Column(modifier = Modifier.padding(16.dp)) {

        Text(strings.language)

        Box {
            Button(
                onClick = { expanded = true },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(selectedLanguage)
            }

            DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false }
            ) {
                languages.forEach { lang ->
                    DropdownMenuItem(onClick = {
                        onLanguageChange(lang)
                        expanded = false
                    }) {
                        Text(lang)
                    }
                }
            }
        }

        if (selectedLanguage == "English" || selectedLanguage == "Angielski") {
            Row(
                modifier = Modifier.padding(top = 16.dp)
            ) {
                Checkbox(
                    checked = owoEnabled,
                    onCheckedChange = { onOwOChange(it) }
                )
                Text(
                    text = strings.makeItRetarded,
                    modifier = Modifier.padding(start = 8.dp)
                )
            }
        }
    }
}
