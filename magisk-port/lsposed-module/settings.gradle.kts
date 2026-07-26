pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Xposed API 82. If this coordinate cannot be resolved, see README for
        // the alternative (vendoring the api jar into libs/).
        maven("https://api.xposed.info/")
    }
}

rootProject.name = "DolbyPassthrough"
