package org.mcduck.pritupir

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.*
import androidx.compose.material.Text
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import org.mcduck.pritupir.ui.*
import org.mcduck.pritupir.ui.screens.*
import org.mcduck.pritupir.ui.lang.*
import org.mcduck.pritupir.ui.ProgressBar

fun currentStrings(language: String, owo: Boolean): Strings {
    return when (language) {
        "Polish" -> StringsPL
        "English" -> if (owo) StringsOwO else StringsEN
        else -> StringsEN
    }
}

fun main() = application {
    Window(
        onCloseRequest = ::exitApplication,
        title = "Pirtupir",
    ) {
        var selectedTab by remember { mutableStateOf(0) }

        var language by remember { mutableStateOf("English") }
        var owo by remember { mutableStateOf(false) }
        val strings = currentStrings(language, owo)

        val tabs = listOf(
            strings.tabLibrary,
            strings.tabSearch,
            strings.tabFriends,
            strings.tabSettings,
            strings.tabAbout
        )

        Box(modifier = Modifier.fillMaxSize()) {

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(bottom = 60.dp)
            ) {
                Tabs(
                    tabs = tabs,
                    selectedTab = selectedTab,
                    onTabChange = { selectedTab = it }
                )

                when (selectedTab) {
                    0 -> {
                        Text("Library")
                    }
                    1 -> {
                        SearchScreen(strings)
                    }
                    2 -> {
                        Text("Friends")
                    }
                    3 -> {
                        SettingsScreen(
                            strings = strings,
                            selectedLanguage = language,
                            onLanguageChange = { language = it },
                            owoEnabled = owo,
                            onOwOChange = { owo = it }
                        )
                    }
                    4 -> {
                        AboutScreen()
                    }
                }
            }

            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .padding(8.dp)
            ) {
                ProgressBar(
                    fileName = "none",
                    progress = 0f,
                    eta = "--:--"
                )
            }
        }
    }
}