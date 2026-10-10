//// `support/admin_ui` の HTML の走査の部品の検査。

import support/admin_ui

/// 属性の値は、名前が空白の直後にある属性だけから、出現順に取る。
pub fn attribute_values_reads_the_named_attribute_only_test() {
  let html = "<a class=\"x y\" data-class=\"z\"></a><b class=\"\" id=\"i\">"
  assert admin_ui.attribute_values(html, "class") == ["x y", ""]
  assert admin_ui.attribute_values(html, "data-class") == ["z"]
  assert admin_ui.attribute_values(html, "title") == []
}

/// タグごとに、`<` と `>` の間の文字列と、その直後から次の `<` までのテキストを返す。最初の
/// `<` より前のテキストは含めない。
pub fn html_tags_pair_each_tag_with_the_text_after_it_test() {
  assert admin_ui.html_tags("lead<p class=\"a\">one<br>two</p>")
    == [#("p class=\"a\"", "one"), #("br", "two"), #("/p", "")]
}
