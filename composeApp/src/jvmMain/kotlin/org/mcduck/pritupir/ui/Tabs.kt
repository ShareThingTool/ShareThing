package org.mcduck.pritupir.ui

import androidx.compose.material.*
import androidx.compose.runtime.*

@Composable
fun Tabs(
    tabs: List<String>,
    selectedTab: Int,
    onTabChange: (Int) -> Unit
) {
    TabRow(selectedTabIndex = selectedTab) {

        tabs.forEachIndexed { index, title ->
            Tab(
                selected = selectedTab == index,
                onClick = { onTabChange(index) },
                text = { Text(title) }
            )
        }
    }
}