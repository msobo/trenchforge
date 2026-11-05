@tool
class_name TFI18n
extends RefCounted
## Translations of the TrenchForge UI.
##
## English is the source language: every user-facing text in the code is
## English and passes through t(), which looks it up in the table of the
## current language (TFLangDE for German) and falls back to the English text.
## Format strings are translated before formatting, so a translation keeps
## the placeholders in the same order.
##
## The language is the editor setting trenchforge/interface/language
## (TFEditorSettings); changing it rebuilds the toolbar and docks.
##
## TrenchForge texts never go through Godot's editor translation: its UI
## controls disable auto translation, otherwise a German editor would
## translate terms like "Cut" or "Select" on its own.

const DEFAULT_LANGUAGE := "en"
## Language code -> native name (shown untranslated in the settings).
const LANGUAGES := {
	"en": "English",
	"de": "Deutsch",
}

static var language := DEFAULT_LANGUAGE


static func t(text: String) -> String:
	if language == DEFAULT_LANGUAGE:
		return text
	return table(language).get(text, text)


## Name of an undo action: "TrenchForge: <translated text>".
static func action(text: String) -> String:
	return "TrenchForge: " + t(text)


## Sets the language; unknown codes fall back to English.
static func set_language(code: String) -> void:
	language = code if LANGUAGES.has(code) else DEFAULT_LANGUAGE


## English text -> translation for a language ({} for English).
static func table(code: String) -> Dictionary:
	match code:
		"de":
			return TFLangDE.STRINGS
	return {}
