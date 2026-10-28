import 'package:html/parser.dart' as html;

import 'rss_models.dart';

/// Retain the source HTML in storage, but render only passive article content.
/// This renderer has no scripts, embedded webviews, forms or event handlers.
String rssDisplayHtml(String source, String? base) {
  final fragment = html.parseFragment(source);
  for (final element in fragment.querySelectorAll(
      'script, style, iframe, object, embed, form, input, button, link, meta, video, audio, source, svg')) {
    element.remove();
  }
  for (final element in fragment.querySelectorAll('*')) {
    final href = rssWebUrl(element.attributes['href'], base);
    final src = rssWebUrl(element.attributes['src'], base);
    final alt = element.attributes['alt'];
    element.attributes.clear();
    if (element.localName == 'a' && href != null) {
      element.attributes['href'] = href;
    }
    if (element.localName == 'img') {
      if (src == null) {
        element.remove();
        continue;
      }
      element.attributes['src'] = src;
      if (alt != null) element.attributes['alt'] = alt;
    }
  }
  return fragment.outerHtml;
}
