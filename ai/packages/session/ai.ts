<TeXmacs|2.1.2>

<style|source>

<\body>
  <\active*>
    <\src-title>
      <src-package|ai|1.0>

      <src-purpose|AI Assistant session style>
    </src-title>
  </active*>

  <use-package|doc>

  <\active*>
    <\src-comment>
      AI session environment
    </src-comment>
  </active*>

  <assign|ai-prompt-color|dark green>

  <assign|ai-response-color|dark blue>

  <assign|ai-input|<macro|prompt|body|<style-with|src-compact|none|<compound|generic-input|<with|color|<value|ai-prompt-color>|<arg|prompt>>|<arg|body>>>>>

  <assign|ai-output|<macro|body|<style-with|src-compact|none|<compound|generic-output|<with|color|<value|ai-response-color>|<arg|body>>>>>>
</body>

<initial|<\collection>
</collection>>
