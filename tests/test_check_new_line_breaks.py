#!/usr/bin/env python3
"""Unit tests for check-new-line-breaks.

Covers sentence-splitting, block detection, clause detection, markup stripping,
diff scoping, moved-content multiset exemptions, Code Quality reporting, and CLI plumbing.
"""

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

_MOD_PATH = Path(__file__).resolve().parent.parent / "scripts" / "check-new-line-breaks.py"
_spec = importlib.util.spec_from_file_location("check_new_line_breaks", _MOD_PATH)
assert _spec is not None and _spec.loader is not None, f"Could not load {_MOD_PATH}"
nlb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nlb)


class TestSentenceSplitting(unittest.TestCase):
    def test_splits_two_plain_sentences(self):
        self.assertEqual(
            nlb.split_sentences("First one. Second one."),
            ["First one.", "Second one."],
        )

    def test_single_sentence_is_not_split(self):
        self.assertEqual(
            nlb.split_sentences("Just one sentence here."),
            ["Just one sentence here."],
        )

    def test_abbreviation_period_does_not_split(self):
        result = nlb.split_sentences("See e.g. the manual for details.")
        self.assertEqual(len(result), 1)

    def test_period_inside_inline_code_does_not_split(self):
        result = nlb.split_sentences("Run `python3 -m pytest .` to test it.")
        self.assertEqual(len(result), 1)

    def test_period_inside_multi_backtick_code_does_not_split(self):
        result = nlb.split_sentences("Run ``python3 -m unittest -k .`` to test it.")
        self.assertEqual(len(result), 1)
        self.assertEqual(
            nlb.split_sentences("Run ``a. b.`` now. Then continue."),
            ["Run ``a. b.`` now.", "Then continue."],
        )

    def test_bold_close_is_a_sentence_boundary(self):
        result = nlb.split_sentences(
            "**Ending the head poll does not end the PR watch.** "
            "The two run at different frequencies."
        )
        self.assertEqual(
            result,
            [
                "**Ending the head poll does not end the PR watch.**",
                "The two run at different frequencies.",
            ],
        )

    def test_italic_close_is_a_sentence_boundary(self):
        result = nlb.split_sentences("See the note.* Then continue with the next point.")
        self.assertEqual(
            result,
            ["See the note.*", "Then continue with the next point."],
        )

    def test_underscore_emphasis_close_is_a_sentence_boundary(self):
        result = nlb.split_sentences(
            "__Ending the head poll does not end the PR watch.__ "
            "The two run at different rates."
        )
        self.assertEqual(
            result,
            [
                "__Ending the head poll does not end the PR watch.__",
                "The two run at different rates.",
            ],
        )

    def test_emphasis_close_before_lowercase_does_not_split(self):
        text = "It is **critical.** yet often skipped on the first pass."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_bold_close_line_is_flagged_end_to_end(self):
        flagged = nlb.classify_line(
            "**Ending the head poll does not end the PR watch.** "
            "The two run at different frequencies."
        )
        self.assertEqual(flagged, "sentence")

    def test_lowercase_sentence_start_is_split(self):
        self.assertEqual(
            nlb.split_sentences(
                "agent disabled in both. serodynamics needed the /review path built."
            ),
            [
                "agent disabled in both.",
                "serodynamics needed the /review path built.",
            ],
        )
        self.assertEqual(
            nlb.split_sentences("it went red. renv restored the lockfile."),
            [
                "it went red.",
                "renv restored the lockfile.",
            ],
        )

    def test_lowercase_start_line_is_flagged_end_to_end(self):
        flagged = nlb.classify_line("it went red. renv restored the lockfile.")
        self.assertEqual(flagged, "sentence")

    def test_sentence_boundary_before_digit_splits(self):
        text = "The job failed. 3 retries remain."
        self.assertEqual(
            nlb.split_sentences(text),
            ["The job failed.", "3 retries remain."],
        )
        self.assertEqual(nlb.classify_line(text), "sentence")

    def test_markdown_link_target_with_punctuation_and_title_does_not_split(self):
        text = 'See the [guide](guide.md "Setup. Advanced usage") for details.'
        self.assertEqual(nlb.split_sentences(text), [text])
        self.assertIsNone(nlb.classify_line(text))

        text2 = 'See the [guide](guide.md "Setup. Advanced usage"). Then continue.'
        self.assertEqual(
            nlb.split_sentences(text2),
            ['See the [guide](guide.md "Setup. Advanced usage").', "Then continue."],
        )

    def test_markdown_link_with_balanced_parentheses_in_destination_and_title(self):
        text = '[guide](https://example.org/foo_(bar) "Setup. Advanced usage")'
        self.assertEqual(nlb.split_sentences(text), [text])
        self.assertIsNone(nlb.classify_line(text))

    def test_nested_balanced_parentheses_in_link_target(self):
        text = '[guide](https://example.org/foo_(bar_(baz)) "Setup. Advanced usage")'
        self.assertEqual(nlb.split_sentences(text), [text])
        self.assertIsNone(nlb.classify_line(text))

    def test_markdown_link_with_angle_bracket_destination_containing_parentheses(self):
        text = '[guide](<https://example.org/foo(bar> "Setup. Advanced usage")'
        self.assertEqual(nlb.split_sentences(text), [text])
        self.assertIsNone(nlb.classify_line(text))

    def test_inline_html_attribute_with_periods_does_not_split_sentence(self):
        text = 'Use <span title="First. Second">this value</span> here.'
        self.assertEqual(nlb.split_sentences(text), [text])
        self.assertIsNone(nlb.classify_line(text))

    def test_inline_html_attribute_with_semicolon_does_not_trigger_clause_check(self):
        text = 'Here is a style span <span style="color: red; font-size: 14px; margin-top: 10px;">formatted text</span> in prose.'
        self.assertEqual(
            nlb.strip_inline_markup(text).strip(),
            'Here is a style span formatted text in prose.',
        )
        self.assertFalse(nlb.has_late_semicolon(text))

    def test_decimal_between_digits_does_not_split(self):
        text = "The lockfile drifted to 0.9012 in the diff."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_version_between_digits_does_not_split(self):
        text = "We pinned it to v2.1 for the release."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_version_at_clause_end_does_not_split(self):
        text = "We shipped v2.1. renv restored it after."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_ellipsis_before_lowercase_does_not_split(self):
        text = "wait... foo comes next here now."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_digit_ending_token_before_lowercase_does_not_split(self):
        text = "It ships as plan9. really soon now here."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_single_letter_initial_before_lowercase_does_not_split(self):
        text = "It is used across the U.S. economy at large."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_dotted_initialism_before_uppercase_mid_sentence_does_not_split(self):
        text1 = "Meeting at 9 a.m. Monday morning in room 101."
        self.assertEqual(nlb.split_sentences(text1), [text1])
        text2 = "Meeting at 5 p.m. Friday afternoon."
        self.assertEqual(nlb.split_sentences(text2), [text2])

    def test_initialism_before_proper_noun_does_not_split(self):
        text1 = "The U.S. Supreme Court issued a ruling."
        self.assertEqual(nlb.split_sentences(text1), [text1])
        text2 = "U.S. Department of Health announced new guidelines."
        self.assertEqual(nlb.split_sentences(text2), [text2])
        text3 = "Work in the U.S. Senate continues today."
        self.assertEqual(nlb.split_sentences(text3), [text3])
        text4 = "The U.S. Army maintains the system."
        self.assertEqual(nlb.split_sentences(text4), [text4])
        text5 = "The U.S. First Circuit issued a ruling."
        self.assertEqual(nlb.split_sentences(text5), [text5])

    def test_sentence_final_initialism_before_uppercase_splits(self):
        text = "The service operates in the U.S. The next service is local."
        self.assertEqual(
            nlb.split_sentences(text),
            ["The service operates in the U.S.", "The next service is local."],
        )
        text2 = "Headquarters are in Washington D.C. Next year we expand."
        self.assertEqual(
            nlb.split_sentences(text2),
            ["Headquarters are in Washington D.C.", "Next year we expand."],
        )

    def test_sentence_final_initialism_before_lowercase_sentence_starter_splits(self):
        text = "The service operates in the U.S. renv restores the environment."
        self.assertEqual(
            nlb.split_sentences(text),
            ["The service operates in the U.S.", "renv restores the environment."],
        )

    def test_sentence_final_initialism_before_arbitrary_uppercase_noun_splits(self):
        text = "We operate in the U.S. Customers can enroll online."
        self.assertEqual(
            nlb.split_sentences(text),
            ["We operate in the U.S.", "Customers can enroll online."],
        )

    def test_sentence_final_abbreviation_splits(self):
        text1 = "Install the required tools, etc. Then run the command."
        self.assertEqual(
            nlb.split_sentences(text1),
            ["Install the required tools, etc.", "Then run the command."],
        )
        text2 = "The study was conducted by Smith et al. The results are clear."
        self.assertEqual(
            nlb.split_sentences(text2),
            ["The study was conducted by Smith et al.", "The results are clear."],
        )

    def test_mid_sentence_abbreviation_does_not_split(self):
        text1 = "Install tools, etc., and then run the command."
        self.assertEqual(nlb.split_sentences(text1), [text1])
        text2 = "Install tools, etc. and then run the command."
        self.assertEqual(nlb.split_sentences(text2), [text2])
        text3 = "See Smith et al., 2020 for details."
        self.assertEqual(nlb.split_sentences(text3), [text3])

    def test_dotted_abbreviation_before_lowercase_does_not_split(self):
        text = "The build starts at 9 a.m. sharp every day."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_single_letter_word_before_lowercase_does_not_split(self):
        text = "Option a. really works well in practice here."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_quoted_fragment_before_lowercase_does_not_split(self):
        text = 'He said "stop that." and then walked away.'
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_lowercase_abbreviation_before_lowercase_does_not_split(self):
        text = "Set the timeout to 3 sec. then wait a while."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_lowercase_abbreviation_before_uppercase_does_split(self):
        self.assertEqual(
            nlb.split_sentences("It took 300 ms. The next run was faster."),
            ["It took 300 ms.", "The next run was faster."],
        )
        self.assertEqual(
            nlb.split_sentences("Refer to sec. The details are listed there."),
            ["Refer to sec.", "The details are listed there."],
        )

    def test_added_time_unit_before_lowercase_does_not_split(self):
        text = "Set the retry backoff to 5 min. and then give up."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_incidental_lowercase_abbrev_before_lowercase_does_not_split(self):
        text = "It took 300 ms. then it retried the request."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_no_as_a_word_before_lowercase_does_split(self):
        self.assertEqual(
            nlb.split_sentences("The answer is no. renv handles it fine."),
            ["The answer is no.", "renv handles it fine."],
        )

    def test_number_abbreviation_before_uppercase_does_not_split(self):
        text = "Item No. Three is the failing one here."
        self.assertEqual(nlb.split_sentences(text), [text])

    def test_all_caps_abbreviation_lookalike_still_splits(self):
        self.assertEqual(
            nlb.split_sentences(
                "It was filed with the SEC. The case dragged on for years."
            ),
            [
                "It was filed with the SEC.",
                "The case dragged on for years.",
            ],
        )


class TestBlockDetectors(unittest.TestCase):
    def test_frontmatter_and_heading_excluded(self):
        text = "---\ntitle: x\n---\n# Heading\nPara line.\n"
        self.assertEqual(nlb.prose_line_numbers(text), {5})

    def test_first_line_thematic_break_without_closing_delimiter_is_checked(self):
        text = "---\nParagraph line after thematic break.\n"
        self.assertEqual(nlb.prose_line_numbers(text), {2})

    def test_fenced_code_excluded(self):
        text = "Intro line.\n```\ncode with a period. not prose.\n```\nOutro line.\n"
        self.assertEqual(nlb.prose_line_numbers(text), {1, 5})

    def test_backtick_fence_with_backtick_in_info_string_is_treated_as_prose(self):
        text = (
            "``` bad`info\n"
            "This line is prose because the fence is invalid.\n"
            "```\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 2})

    def test_blockquote_backtick_fence_with_backtick_in_info_string_is_treated_as_prose(self):
        text = (
            "> ``` bad`info\n"
            "> This blockquote line is prose.\n"
            "> ```\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 2})

    def test_setext_underline_indentation_boundary(self):
        # 3 spaces is a valid Setext heading underline, excluding both lines
        text_3_spaces = (
            "First sentence. Second sentence.\n"
            "   ---\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text_3_spaces), set())

        # 4 spaces is NOT a Setext heading underline, so preceding prose line is kept
        text_4_spaces = (
            "First sentence. Second sentence.\n"
            "    ---\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text_4_spaces), {1})

    def test_atx_heading_indentation_boundary(self):
        # 3 spaces is a valid ATX heading, excluded from prose
        text_3_spaces = (
            "Introductory paragraph.\n"
            "   # Heading text\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text_3_spaces), {1})

        # 4 spaces is NOT an ATX heading; continuing a paragraph makes it prose
        text_4_spaces = (
            "Introductory paragraph.\n"
            "    # First sentence. Second sentence.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text_4_spaces), {1, 2})

    def test_table_and_hr_excluded(self):
        text = "| a | b. two sentences. |\n| - | - |\n---\nParagraph text.\n"
        self.assertEqual(nlb.prose_line_numbers(text), {4})

    def test_table_without_outer_pipes_excluded(self):
        text = (
            "Name | Description\n"
            "--- | ---\n"
            "foo | bar. two sentences.\n"
            "Paragraph prose line.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {4})

    def test_multiline_html_comment_excluded(self):
        text = (
            "<!--\n"
            "Interior comment line. Two sentences here.\n"
            "-->\n"
            "Real prose line.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {4})

    def test_single_line_html_comment_excluded(self):
        text = "<!-- one-line comment -->\nReal prose line.\n"
        self.assertEqual(nlb.prose_line_numbers(text), {2})

    def test_blockquote_prose_is_checked(self):
        text = "> First sentence. Second sentence.\n"
        self.assertEqual(nlb.prose_line_numbers(text), {1})

    def test_blockquote_blank_excluded(self):
        text = "> - a bullet\n>\n> prose line\n"
        self.assertEqual(nlb.prose_line_numbers(text), {1, 3})

    def test_blockquote_nested_fence_excluded(self):
        text = "> ```\n> code with a period. not prose.\n> ```\n> prose line\n"
        self.assertEqual(nlb.prose_line_numbers(text), {4})

    def test_nested_blockquote_fence_excluded(self):
        text = (
            "> > ```\n"
            "> > code inside nested bq. not prose.\n"
            "> > ```\n"
            "> > Real prose line inside nested bq.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {4})

    def test_setext_headings_excluded(self):
        text = (
            "Setext Level 1 Heading\n"
            "======================\n"
            "Paragraph one.\n"
            "\n"
            "Setext Level 2 Heading\n"
            "----------------------\n"
            "Paragraph two.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {3, 7})

    def test_indented_code_spaces_and_tabs_excluded(self):
        text = (
            "Paragraph one.\n"
            "\n"
            "    echo 'Done. Next step.'\n"
            "\n"
            "\techo 'Another command. Run now.'\n"
            "\n"
            "Paragraph two.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 7})

    def test_indented_paragraph_continuation_is_checked(self):
        text = (
            "Paragraph one starting line.\n"
            "    Indented continuation line. Second sentence.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 2})

    def test_list_nested_fenced_code_block_excluded(self):
        text = (
            "- List item.\n"
            "\n"
            "    ```python\n"
            "    code line. not prose.\n"
            "    ```\n"
            "\n"
            "Paragraph after list.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 7})

    def test_indented_bullet_is_checked(self):
        text = (
            "Top level.\n"
            "    - Indented sub-bullet. Second sentence.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 2})

    def test_indented_list_continuation_prose_is_checked(self):
        text = (
            "- First bullet.\n"
            "    Continuation line one. Still first bullet.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 2})

    def test_nested_code_block_in_list_is_excluded(self):
        text = (
            "- First bullet.\n"
            "\n"
            "      echo 'Code block inside list. Not prose.'\n"
            "\n"
            "- Second bullet.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 5})

    def test_indented_literal_fence_does_not_open_code_block(self):
        text = (
            "Top level prose.\n"
            "\n"
            "    ```\n"
            "    indented code line\n"
            "\n"
            "Subsequent prose line.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 6})

    def test_blockquote_indented_literal_fence_does_not_open_code_block(self):
        text = (
            "> Top level blockquote prose.\n"
            ">\n"
            ">     ```\n"
            ">     indented code line in bq\n"
            ">\n"
            "> Subsequent blockquote prose line.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 6})

    def test_blockquote_fence_length_matching(self):
        text = (
            "> ````\n"
            "> ```\n"
            "> still inside four-backtick fence in bq.\n"
            "> ````\n"
            "> Real prose line after fence.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {5})

    def test_blockquote_multi_digit_ordered_list_nested_fence_excluded(self):
        text = (
            "> 10. Item in ordered list.\n"
            ">     ```python\n"
            ">     Code line. More code.\n"
            ">     ```\n"
            "> Real prose line after ordered list code.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 5})

    def test_closing_fence_with_trailing_chars_does_not_close(self):
        text = (
            "```python\n"
            "```not-a-close\n"
            "still inside code\n"
            "```\n"
            "prose line\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {5})

    def test_over_indented_closing_fence_does_not_close(self):
        text = (
            "```\n"
            "    ```\n"
            "    code line still inside fence\n"
            "```\n"
            "prose line\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {5})

    def test_html_comment_inside_code_fence_does_not_escape(self):
        text = (
            "```html\n"
            "<!-- unclosed comment inside code fence\n"
            "```\n"
            "Real prose line after fence.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {4})

    def test_raw_html_blocks_excluded_from_prose(self):
        text = (
            "<script type=\"text/javascript\">\n"
            "  const a = 'Sentence one. Sentence two.';\n"
            "  console.log(a);\n"
            "</script>\n"
            "<style>\n"
            "  .cls { content: 'Style one. Style two.'; }\n"
            "</style>\n"
            "<pre>\n"
            "  Preformatted text. Two sentences.\n"
            "</pre>\n"
            "<textarea>\n"
            "  Textarea content. Two sentences.\n"
            "</textarea>\n"
            "<?php\n"
            "  echo 'Processing instruction. Two sentences.';\n"
            "?>\n"
            "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\">\n"
            "<![CDATA[\n"
            "  CDATA content. Two sentences.\n"
            "]]>\n"
            "<div class=\"container\">\n"
            "  <p>HTML paragraph inside div block.</p>\n"
            "</div>\n"
            "\n"
            "Real prose line after HTML blocks.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {25})

    def test_blockquote_raw_html_blocks_excluded_from_prose(self):
        text = (
            "> <script>\n"
            "> const msg = 'Inside script in blockquote. Two sentences.';\n"
            "> </script>\n"
            "> <div>\n"
            "> <p>Inside div in blockquote.</p>\n"
            "> </div>\n"
            ">\n"
            "> Real prose line in blockquote.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {8})

    def test_type7_html_block_excluded_from_prose(self):
        text = (
            "<x-widget>\n"
            "  Internal configuration sentence. Another sentence.\n"
            "</x-widget>\n"
            "\n"
            "Real prose line after custom element block.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {5})

    def test_type7_html_tag_inside_paragraph_does_not_start_html_block(self):
        text = (
            "First sentence of paragraph.\n"
            "<x-widget>\n"
            "Third sentence continuing paragraph.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 2, 3})

    def test_blockquote_type7_html_block_followed_by_blank_separated_prose(self):
        text = (
            "> <custom-tag>\n"
            ">   Config line inside custom tag. Second sentence.\n"
            "> </custom-tag>\n"
            ">\n"
            "> Subsequent blockquote prose sentence. Another sentence.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {5})

    def test_blockquote_multiline_html_comment(self):
        text = (
            "> Top blockquote prose line.\n"
            ">\n"
            "> <!-- Multiline comment in blockquote.\n"
            "> Still inside comment. Second sentence.\n"
            "> -->\n"
            ">\n"
            "> Bottom blockquote prose line.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 7})

    def test_spaced_thematic_break_followed_by_indented_code(self):
        text = (
            "Top prose paragraph.\n"
            "\n"
            "* * *\n"
            "\n"
            "    indented_code_line(param1, param2)\n"
            "\n"
            "Bottom prose paragraph.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 7})

    def test_blockquote_indented_paragraph_continuation_is_checked(self):
        text = (
            "> Paragraph line.\n"
            ">     Indented continuation sentence. Second sentence.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 2})

    def test_blockquote_bullet_prose_is_checked(self):
        text = (
            "> - First bullet sentence. Second sentence.\n"
            "> - Second bullet item.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 2})
        self.assertEqual(
            nlb.line_content("> - First bullet sentence. Second sentence."),
            "First bullet sentence. Second sentence.",
        )

    def test_ordered_list_with_parenthesis_delimiter(self):
        text = (
            "1) First numbered item with paren.\n"
            "   Continuation prose line under item.\n"
            "2) Second item.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 2, 3})

    def test_same_line_html_comment_suffix_is_checked(self):
        text = (
            "<!-- context --> First sentence. Second sentence.\n"
            "<!-- full line comment -->\n"
            "Prose line.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 3})
        content = nlb.line_content("<!-- context --> First sentence. Second sentence.")
        self.assertEqual(content, "First sentence. Second sentence.")
        self.assertEqual(nlb.classify_line(content), "sentence")

    def test_multiline_html_comment_suffix_is_checked(self):
        text = (
            "<!-- multiline\n"
            "comment block\n"
            "--> First sentence. Second sentence.\n"
            "Another line.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {3, 4})
        content = nlb.line_content("--> First sentence. Second sentence.")
        self.assertEqual(content, "First sentence. Second sentence.")
        self.assertEqual(nlb.classify_line(content), "sentence")

    def test_multiline_html_comment_opened_after_prose_is_checked(self):
        text = (
            "Visible introduction. <!--\n"
            "Internal comment. Another internal sentence.\n"
            "-->\n"
            "Subsequent visible prose line.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {1, 4})
        content = nlb.line_content("Visible introduction. <!--")
        self.assertEqual(content, "Visible introduction.")
        self.assertIsNone(nlb.classify_line(content))

    def test_indented_code_at_document_start_and_after_heading_excluded(self):
        text1 = '    echo "First command. Run another."\n'
        self.assertEqual(nlb.prose_line_numbers(text1), set())

        text2 = (
            "# Heading\n"
            '    echo "First command. Run another."\n'
            "Regular prose line.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text2), {3})

        text3 = (
            "Regular paragraph line.\n"
            "    Indented continuation line. Another sentence.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text3), {1, 2})

    def test_reference_link_definitions_excluded(self):
        text = (
            '[guide]: https://example.org/docs "Setup instructions. Advanced usage"\n'
            "[multiline-guide]: https://example.org/docs\n"
            '    "Title on next line. Second sentence."\n'
            "Real prose line here.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {4})

    def test_reference_link_definitions_inside_blockquotes_excluded(self):
        text = (
            '> [guide]: https://example.org/docs "Setup instructions. Advanced usage"\n'
            "> [multiline-guide]: https://example.org/docs\n"
            '>     "Title on next line. Second sentence."\n'
            "> Real prose line here.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {4})

    def test_multiline_reference_definition_with_destination_ending_in_parenthesis(self):
        text = (
            '[guide]: https://example.org/docs(foo)\n'
            '  "Setup instructions. Advanced usage."\n'
            "Real prose line here.\n"
        )
        self.assertEqual(nlb.prose_line_numbers(text), {3})

    def test_invalid_reference_definition_treated_as_prose(self):
        text = "[Note]: First sentence. Second sentence.\n"
        self.assertEqual(nlb.prose_line_numbers(text), {1})

    def test_seven_hashes_line_is_treated_as_prose(self):
        text = "####### Seven hashes paragraph. Second sentence.\n"
        self.assertEqual(nlb.prose_line_numbers(text), {1})

    def test_nested_blockquote_line_content(self):
        self.assertEqual(
            nlb.line_content("> > - Nested bullet text"),
            "Nested bullet text",
        )

    def test_bullet_marker_is_stripped(self):
        self.assertEqual(nlb.line_content("- some text here"), "some text here")

    def test_blockquote_prefix_is_stripped(self):
        self.assertEqual(nlb.line_content("> some text here"), "some text here")

    def test_plain_line_is_returned_stripped(self):
        self.assertEqual(nlb.line_content("  plain text  "), "plain text")


class TestClauseBreaks(unittest.TestCase):
    _LONG_SEMICOLON = (
        "The first clause carries the main point of the sentence; "
        "the second one stands entirely on its own."
    )

    def test_strip_inline_markup_drops_code_spans_and_link_targets(self):
        self.assertEqual(nlb.strip_inline_markup("run `a; b` now"), "run  now")
        self.assertEqual(
            nlb.strip_inline_markup("see [docs](http://x.com/a;b)"), "see [docs]"
        )

    def test_long_line_with_midline_semicolon_is_a_clause_break(self):
        self.assertGreater(len(self._LONG_SEMICOLON), 80)
        self.assertTrue(nlb.has_late_semicolon(self._LONG_SEMICOLON))

    def test_short_line_with_semicolon_is_not_flagged(self):
        self.assertFalse(nlb.has_late_semicolon("Do this; then that."))

    def test_trailing_semicolon_is_not_a_clause_break(self):
        text = "A clause that is quite long indeed and already ends where it should;"
        self.assertFalse(nlb.has_late_semicolon(text, min_length=10))

    def test_semicolon_only_inside_code_span_is_not_a_clause_break(self):
        text = "Invoke the helper with `for x in xs; do thing; done` and read its output."
        self.assertFalse(nlb.has_late_semicolon(text, min_length=10))

    def test_semicolon_inside_a_multi_backtick_code_span_is_not_a_clause_break(self):
        text = (
            "Invoke the helper with ``for x in xs; do thing; done`` "
            "and then read all of its output carefully."
        )
        self.assertGreater(len(text), 80)
        self.assertNotIn(";", nlb.strip_inline_markup(text))
        self.assertFalse(nlb.has_late_semicolon(text))

    def test_a_backtick_inside_a_multi_backtick_span_does_not_end_it(self):
        self.assertEqual(nlb.strip_inline_markup("use ``a `b` c`` here"), "use  here")

    def test_a_leading_semicolon_does_not_mask_a_later_interior_one(self):
        text = (
            "`cfg`; a first clause that runs on for quite a while here; "
            "and a second one after it."
        )
        self.assertTrue(nlb.strip_inline_markup(text).lstrip().startswith(";"))
        self.assertTrue(nlb.has_late_semicolon(text, min_length=10))

    def test_leading_semicolon_is_not_a_clause_break(self):
        text = "`configure`; " + "the remaining prose runs on for a while and is long indeed."
        self.assertTrue(nlb.strip_inline_markup(text).lstrip().startswith(";"))
        self.assertFalse(nlb.has_late_semicolon(text, min_length=10))

    def test_long_line_without_semicolon_is_not_flagged(self):
        text = "A single long clause that simply runs on for a good while without any break."
        self.assertFalse(nlb.has_late_semicolon(text, min_length=10))

    def test_clause_min_length_is_configurable(self):
        text = "Short; line."
        self.assertFalse(nlb.has_late_semicolon(text))
        self.assertTrue(nlb.has_late_semicolon(text, min_length=5))

    def test_length_gate_measures_visible_prose_not_raw_markdown(self):
        text = "See [x](https://example.com/" + "a" * 90 + "); ok now."
        self.assertGreater(len(text), 80)
        self.assertLess(len(nlb.strip_inline_markup(text)), 80)
        self.assertFalse(nlb.has_late_semicolon(text))

    def test_a_long_code_span_does_not_inflate_a_short_line_past_the_gate(self):
        text = "Run `" + "x" * 90 + "` first; then stop."
        self.assertGreater(len(text), 80)
        self.assertFalse(nlb.has_late_semicolon(text))

    def test_markup_carrying_a_semicolon_is_not_a_clause_break(self):
        cases = [
            ("bare URL with semicolon in query", "Open https://example.com/search?a=1;b=2 in a browser for details, please, and read on"),
            ("bare URL inflating line", "See https://example.com/docs/some/quite/long/path/page.html; it explains the rest."),
            ("autolink", "See <https://example.com/docs/some/quite/long/path/page.html>; it explains the rest."),
            ("HTML entity", "This sentence uses fish &amp; chips as an example of a common food pairing today"),
        ]
        for label, text in cases:
            with self.subTest(label=label):
                self.assertFalse(nlb.has_late_semicolon(text))

    def test_clause_boundary_after_a_bare_url_survives_stripping(self):
        text = (
            "The full derivation is written up at https://example.com/paper.pdf; "
            "the second clause stands entirely on its own."
        )
        self.assertEqual(
            nlb.strip_inline_markup(text).rstrip(),
            "The full derivation is written up at ; the second clause stands entirely on its own.",
        )
        self.assertTrue(nlb.has_late_semicolon(text))

    def test_identical_prose_does_not_flip_verdict_on_link_syntax(self):
        bare = "Open https://example.com/search?a=1;b=2 in a browser for details, please, and read on"
        bracketed = (
            "Open [the search page](https://example.com/search?a=1;b=2) in a browser "
            "for details, please, and read on"
        )
        self.assertEqual(nlb.has_late_semicolon(bare), nlb.has_late_semicolon(bracketed))

    def test_min_length_is_inclusive(self):
        text = "a" * 68 + "; " + "b" * 10
        self.assertEqual(len(text), 80)
        self.assertTrue(nlb.has_late_semicolon(text, min_length=80))
        self.assertFalse(nlb.has_late_semicolon(text, min_length=81))

    def test_sentence_reason_wins_over_clause_reason(self):
        text = self._LONG_SEMICOLON + " And a second sentence follows it."
        self.assertEqual(nlb.classify_line(text), "sentence")

    def test_clause_check_can_be_disabled(self):
        self.assertEqual(nlb.classify_line(self._LONG_SEMICOLON), "clause")
        self.assertIsNone(nlb.classify_line(self._LONG_SEMICOLON, clause_breaks=False))

    def test_leading_semicolon_after_a_stripped_span_is_not_a_clause_break(self):
        padding = "word " * 20
        text = "`code` ; " + padding
        self.assertFalse(nlb.has_late_semicolon(text))
        spaced = "`code` ; " + padding
        tight = "`code`; " + padding
        self.assertEqual(nlb.has_late_semicolon(spaced), nlb.has_late_semicolon(tight))


class TestDiffScoping(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.tmp_path = Path(self.test_dir)
        subprocess.run(["git", "init", "-q"], cwd=self.tmp_path, check=True)
        subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=self.tmp_path, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=self.tmp_path, check=True)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _commit(self, message: str) -> None:
        subprocess.run(["git", "add", "-A"], cwd=self.tmp_path, check=True)
        subprocess.run(["git", "commit", "-q", "-m", message], cwd=self.tmp_path, check=True)

    def _find(self, base_ref: str = "", globs=("*.md",), clause_breaks=True, min_length=80, ignores=None):
        cwd = os.getcwd()
        os.chdir(self.tmp_path)
        try:
            return nlb.find_violations(base_ref, list(globs), ignores or [], clause_breaks, min_length)
        finally:
            os.chdir(cwd)

    def test_diff_scope_flags_newly_added_violation(self):
        (self.tmp_path / "notes.md").write_text("# Notes\n\n- A short bullet.\n")
        self._commit("base")
        (self.tmp_path / "notes.md").write_text(
            "# Notes\n\n- A short bullet.\n- Two sentences. On one line.\n"
        )
        self._commit("add violation")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual([(v.path, v.line) for v in violations], [("notes.md", 4)])
        self.assertEqual([v.reason for v in violations], ["sentence"])

    def test_diff_scope_does_not_reflag_pre_existing_drift(self):
        (self.tmp_path / "notes.md").write_text("- Fine as-is. Two sentences here.\n")
        self._commit("base with pre-existing drift")
        (self.tmp_path / "notes.md").write_text(
            "- Fine as-is. Two sentences here.\n- A brand-new short bullet.\n"
        )
        self._commit("unrelated addition")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual(violations, [])

    def test_moved_block_to_new_file_is_not_flagged(self):
        (self.tmp_path / "notes.md").write_text(
            "# Notes\n\n- Grandfathered drift. Two sentences on one line.\n"
        )
        self._commit("base with pre-existing drift")
        (self.tmp_path / "notes.md").write_text("# Notes\n")
        (self.tmp_path / "moved.md").write_text(
            "- Grandfathered drift. Two sentences on one line.\n"
        )
        self._commit("split the drift into a new file")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual(violations, [])

    def test_new_violation_in_new_file_is_still_flagged(self):
        (self.tmp_path / "notes.md").write_text("# Notes\n")
        self._commit("base")
        (self.tmp_path / "fresh.md").write_text("- Genuinely new. Two sentences.\n")
        self._commit("new file with a new violation")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual([(v.path, v.line) for v in violations], [("fresh.md", 1)])

    def test_mixed_moved_and_new_lines_flags_only_the_new_one(self):
        (self.tmp_path / "notes.md").write_text(
            "# Notes\n\n- Grandfathered drift. Two sentences on one line.\n"
        )
        self._commit("base with pre-existing drift")
        (self.tmp_path / "notes.md").write_text("# Notes\n")
        (self.tmp_path / "moved.md").write_text(
            "- Grandfathered drift. Two sentences on one line.\n"
            "- Genuinely new. Two sentences.\n"
        )
        self._commit("split plus a new violation")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual([(v.path, v.line) for v in violations], [("moved.md", 2)])

    def test_line_edited_during_move_is_flagged(self):
        (self.tmp_path / "notes.md").write_text(
            "# Notes\n\n- Grandfathered drift. Two sentences on one line.\n"
        )
        self._commit("base with pre-existing drift")
        (self.tmp_path / "notes.md").write_text("# Notes\n")
        (self.tmp_path / "moved.md").write_text(
            "- Grandfathered drift, reworded in transit. Two sentences on one line.\n"
        )
        self._commit("move with an edit")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual([(v.path, v.line) for v in violations], [("moved.md", 1)])

    def test_duplicate_of_untouched_base_line_is_still_flagged(self):
        (self.tmp_path / "untouched.md").write_text(
            "- Grandfathered drift. Two sentences on one line.\n"
        )
        self._commit("base with pre-existing drift elsewhere")
        (self.tmp_path / "fresh.md").write_text(
            "- Grandfathered drift. Two sentences on one line.\n"
        )
        self._commit("new file duplicating an untouched line")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual([(v.path, v.line) for v in violations], [("fresh.md", 1)])

    def test_one_deletion_exempts_at_most_one_addition(self):
        (self.tmp_path / "notes.md").write_text(
            "# Notes\n\n- Grandfathered drift. Two sentences on one line.\n"
        )
        self._commit("base with pre-existing drift")
        (self.tmp_path / "notes.md").write_text("# Notes\n")
        (self.tmp_path / "a.md").write_text(
            "- Grandfathered drift. Two sentences on one line.\n"
        )
        (self.tmp_path / "b.md").write_text(
            "- Grandfathered drift. Two sentences on one line.\n"
        )
        (self.tmp_path / "c.md").write_text(
            "- Grandfathered drift. Two sentences on one line.\n"
        )
        self._commit("one deletion, three identical additions")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual(len(violations), 2)

    def test_two_deletions_exempt_two_additions(self):
        (self.tmp_path / "notes.md").write_text(
            "# Notes\n\n- Grandfathered drift. Two sentences on one line.\n"
            "\n## Later\n\n- Grandfathered drift. Two sentences on one line.\n"
        )
        self._commit("base with the same drift twice")
        (self.tmp_path / "notes.md").write_text("# Notes\n\n## Later\n")
        (self.tmp_path / "a.md").write_text(
            "- Grandfathered drift. Two sentences on one line.\n"
        )
        (self.tmp_path / "b.md").write_text(
            "- Grandfathered drift. Two sentences on one line.\n"
        )
        self._commit("two deletions, two identical additions")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual(violations, [])

    def test_deleted_line_in_ignored_file_does_not_exempt_addition_in_checked_file(self):
        (self.tmp_path / "ignored.md").write_text(
            "- Grandfathered drift in ignored file. Two sentences on one line.\n"
        )
        self._commit("base with ignored file")
        (self.tmp_path / "ignored.md").write_text("# Cleared\n")
        (self.tmp_path / "checked.md").write_text(
            "- Grandfathered drift in ignored file. Two sentences on one line.\n"
        )
        self._commit("delete from ignored file and add to checked file")

        violations, skipped = self._find(
            base_ref="HEAD~1",
            ignores=[re.compile(r"^ignored\.md$")],
        )
        self.assertFalse(skipped)
        self.assertEqual([(v.path, v.line) for v in violations], [("checked.md", 1)])

    def test_moved_line_starting_with_two_dashes_is_exempt(self):
        (self.tmp_path / "notes.md").write_text(
            "# Notes\n\n-- Dashed drift, yes. Two sentences on one line.\n"
        )
        self._commit("base with dashed drift")
        (self.tmp_path / "notes.md").write_text("# Notes\n")
        (self.tmp_path / "moved.md").write_text(
            "-- Dashed drift, yes. Two sentences on one line.\n"
        )
        self._commit("move the dashed line")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual(violations, [])

    def test_added_line_starting_with_two_pluses_is_still_flagged(self):
        (self.tmp_path / "notes.md").write_text("# Notes\n")
        self._commit("base")
        (self.tmp_path / "notes.md").write_text(
            "# Notes\n\n++ Plussed drift, yes. Two sentences on one line.\n"
            "- Ordinary new drift. Two sentences on one line.\n"
        )
        self._commit("add a plussed line and an ordinary one")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual(
            [(v.path, v.line) for v in violations],
            [("notes.md", 3), ("notes.md", 4)],
        )

    def test_unresolvable_base_ref_skips_rather_than_scanning_whole_tree(self):
        (self.tmp_path / "notes.md").write_text("- Long-standing violation. Two sentences.\n")
        self._commit("only commit")

        violations, skipped = self._find(base_ref="deadbeefdeadbeef")
        self.assertTrue(skipped)
        self.assertEqual(violations, [])

    def test_empty_base_ref_skips_rather_than_scanning_whole_tree(self):
        (self.tmp_path / "notes.md").write_text("- A violation. Right here.\n")
        self._commit("only commit")

        violations, skipped = self._find(base_ref="")
        self.assertTrue(skipped)
        self.assertEqual(violations, [])

    def test_final_line_replacement_without_trailing_newline(self):
        (self.tmp_path / "notes.md").write_text("# Notes\nOld line without newline")
        self._commit("base without trailing newline")

        (self.tmp_path / "notes.md").write_text("# Notes\nNew replacement line. Two sentences here")
        self._commit("replace final line without trailing newline")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual([(v.path, v.line) for v in violations], [("notes.md", 2)])

    def test_non_ascii_filename_diff_is_handled(self):
        (self.tmp_path / "café.md").write_text("# Café\n")
        self._commit("base with non-ascii filename")

        (self.tmp_path / "café.md").write_text("# Café\n\n- Non-ascii file violation. Two sentences.\n")
        self._commit("modify non-ascii file")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual([(v.path, v.line) for v in violations], [("café.md", 3)])

    def test_invalid_utf8_in_changed_file_flags_unreadable_violation(self):
        (self.tmp_path / "notes.md").write_text("# Notes\n")
        self._commit("base")

        # Write invalid UTF-8 byte sequence
        (self.tmp_path / "notes.md").write_bytes(b"# Notes\n\xff\xfe invalid utf8\n")
        self._commit("write invalid utf8")

        violations, skipped = self._find(base_ref="HEAD~1")
        self.assertFalse(skipped)
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].path, "notes.md")
        self.assertEqual(violations[0].reason, "unreadable")

    def test_unreadable_changed_file_flags_unreadable_violation(self):
        (self.tmp_path / "notes.md").write_text("# Notes\n")
        self._commit("base")

        (self.tmp_path / "notes.md").write_text("# Notes\nNew line\n")
        self._commit("modify file")

        with patch.object(Path, "read_text", side_effect=OSError("Permission denied")):
            violations, skipped = self._find(base_ref="HEAD~1")
            self.assertFalse(skipped)
            self.assertEqual(len(violations), 1)
            self.assertEqual(violations[0].path, "notes.md")
            self.assertEqual(violations[0].reason, "unreadable")

    def test_symlink_to_external_file_is_skipped_without_reading(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
            f.write("External secret line one. External secret line two.\n")
            external_path = Path(f.name)
        try:
            (self.tmp_path / "notes.md").write_text("# Notes\n")
            self._commit("base")

            (self.tmp_path / "notes.md").unlink()
            (self.tmp_path / "notes.md").symlink_to(external_path)
            self._commit("add symlink to external file")

            violations, skipped = self._find(base_ref="HEAD~1")
            self.assertFalse(skipped)
            self.assertEqual(violations, [])
        finally:
            external_path.unlink(missing_ok=True)

    def test_unquote_git_path_with_octal_and_special_escapes(self):
        self.assertEqual(nlb._unquote_git_path('"b/caf\\303\\251\\tnotes.md"'), "b/café\tnotes.md")
        self.assertEqual(nlb._unquote_git_path('"b/path with \\"quotes\\".md"'), 'b/path with "quotes".md')
        self.assertEqual(nlb._unquote_git_path("b/plain.md"), "b/plain.md")


class TestMainAndReporting(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.tmp_path = Path(self.test_dir)
        subprocess.run(["git", "init", "-q"], cwd=self.tmp_path, check=True)
        subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=self.tmp_path, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=self.tmp_path, check=True)

        (self.tmp_path / "notes.md").write_text("# Notes\n\n- A short bullet.\n")
        subprocess.run(["git", "add", "-A"], cwd=self.tmp_path, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "base"], cwd=self.tmp_path, check=True)

        long_clause = (
            "The first clause carries the main point of the sentence; "
            "the second one stands entirely on its own."
        )
        (self.tmp_path / "notes.md").write_text(
            f"# Notes\n\n- A short bullet.\n- {long_clause}\n"
        )
        subprocess.run(["git", "add", "-A"], cwd=self.tmp_path, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "add clause violation"], cwd=self.tmp_path, check=True)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_codequality_json_generation(self):
        report_path = self.tmp_path / "gl-code-quality-report.json"
        violations = [
            nlb.Violation(path="notes.md", line=4, preview="The first clause...", reason="clause")
        ]
        nlb.write_codequality_report(violations, str(report_path))
        self.assertTrue(report_path.is_file())
        data = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["location"]["path"], "notes.md")
        self.assertEqual(data[0]["location"]["lines"]["begin"], 4)
        self.assertEqual(data[0]["check_name"], "semantic-line-breaks/clause")

    def test_env_readers(self):
        os.environ["NLB_TEST_FLAG"] = "true"
        self.assertTrue(nlb._env_flag("NLB_TEST_FLAG", False))
        os.environ["NLB_TEST_FLAG"] = "false"
        self.assertFalse(nlb._env_flag("NLB_TEST_FLAG", True))
        os.environ["NLB_TEST_FLAG"] = "invalid"
        self.assertTrue(nlb._env_flag("NLB_TEST_FLAG", True))

        os.environ["NLB_TEST_INT"] = "100"
        self.assertEqual(nlb._env_int("NLB_TEST_INT", 80), 100)
        os.environ["NLB_TEST_INT"] = "invalid"
        self.assertEqual(nlb._env_int("NLB_TEST_INT", 80), 80)
        os.environ["NLB_TEST_INT"] = "-5"
        self.assertEqual(nlb._env_int("NLB_TEST_INT", 80), 80)

    def test_nonnegative_int_validator_accepts_valid_and_rejects_negative(self):
        self.assertEqual(nlb._nonnegative_int("80"), 80)
        self.assertEqual(nlb._nonnegative_int("0"), 0)
        with self.assertRaises(argparse.ArgumentTypeError):
            nlb._nonnegative_int("-1")
        with self.assertRaises(argparse.ArgumentTypeError):
            nlb._nonnegative_int("invalid")


if __name__ == "__main__":
    unittest.main()
