#!/usr/bin/env python3
"""
AI Helper Script for Mogan STEM
Supports multiple AI providers: Claude, Gemini (coming soon)
Also provides file picker functionality via tkinter.
"""

import sys
import json
import base64
import os


def pick_file():
    """Open a native macOS file dialog to select a PDF file."""
    try:
        import subprocess

        # Use macOS native file picker via osascript
        script = '''
        set theFile to choose file with prompt "Select PDF file" of type {"pdf", "PDF"} default location (path to documents folder)
        return POSIX path of theFile
        '''

        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True,
            text=True,
            timeout=300  # 5 minutes for user to select
        )

        if result.returncode == 0:
            path = result.stdout.strip()
            return {'success': True, 'path': path}
        else:
            # User cancelled
            return {'success': True, 'path': ''}

    except subprocess.TimeoutExpired:
        return {'success': False, 'error': 'Timeout waiting for file selection'}
    except Exception as e:
        return {'success': False, 'error': str(e)}


def call_claude(question, pdf_path=None, api_key=None):
    """Call Claude API with optional PDF document."""
    import requests

    if not api_key:
        raise ValueError("Claude API key is required")

    url = 'https://api.anthropic.com/v1/messages'
    headers = {
        'x-api-key': api_key,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json'
    }

    content = []

    # Add PDF document if provided
    if pdf_path and os.path.exists(pdf_path):
        with open(pdf_path, 'rb') as f:
            pdf_b64 = base64.b64encode(f.read()).decode('utf-8')
        content.append({
            'type': 'document',
            'source': {
                'type': 'base64',
                'media_type': 'application/pdf',
                'data': pdf_b64
            }
        })

    # Add the question text
    content.append({'type': 'text', 'text': question})

    data = {
        'model': 'claude-sonnet-4-20250514',
        'max_tokens': 16384,
        'system': (
            'Your response will be rendered in a LaTeX document. '
            'You MUST follow these rules strictly:\n'
            '1) Use LaTeX formatting ONLY. NEVER use markdown syntax.\n'
            '2) For bold text use \\textbf{text}, NEVER use **text** or *text*.\n'
            '3) For italic text use \\textit{text}, NEVER use *text*.\n'
            '4) NEVER use asterisks (*) anywhere in your output for any purpose.\n'
            '5) For section headers use \\section{}, \\subsection{}, NEVER use ## or #.\n'
            '6) For inline math use $expression$, for display math use $$expression$$ or \\begin{equation}.\n'
            '7) Use \\sqrt{}, \\frac{}{}, ^{}, _{} for math notation.\n'
            '8) For bullet lists use \\begin{itemize}\\item...\\end{itemize}.\n'
            '9) For numbered lists use \\begin{enumerate}\\item...\\end{enumerate}.\n'
            '10) NEVER use Unicode superscripts or subscripts - use LaTeX math mode instead.\n'
            '11) Write plain author names without any formatting characters between letters.'
        ),
        'messages': [{'role': 'user', 'content': content}]
    }

    response = requests.post(url, headers=headers, json=data, timeout=600)
    response.raise_for_status()

    result = response.json()
    if 'content' in result and len(result['content']) > 0:
        text = result['content'][0]['text']
        truncated = result.get('stop_reason') == 'max_tokens'
        return text, truncated
    else:
        raise ValueError("No content in Claude response")


def call_gemini(question, pdf_path=None, api_key=None):
    """Call Gemini API with optional PDF document."""
    # TODO: Add Gemini support
    return 'Gemini support coming soon'


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print(json.dumps({
            'success': False,
            'error': 'Usage: ai-helper.py pick_file | ai-helper.py \'{"provider": "claude", ...}\''
        }, separators=(',', ':')))
        sys.exit(1)

    # Check for special commands
    if sys.argv[1] == 'pick_file':
        result = pick_file()
        print(json.dumps(result, separators=(',', ':')))
        sys.exit(0 if result.get('success') else 1)

    try:
        # Parse JSON config from command line
        config = json.loads(sys.argv[1])

        provider = config.get('provider', 'claude')
        question = config.get('question')
        pdf_path = config.get('pdf_path')
        api_key = config.get('api_key')

        if not question:
            raise ValueError("Question is required")

        # Call appropriate provider
        if provider == 'claude':
            answer, truncated = call_claude(question, pdf_path, api_key)
        elif provider == 'gemini':
            answer = call_gemini(question, pdf_path, api_key)
            truncated = False
        else:
            raise ValueError(f'Unknown provider: {provider}')

        # Output success response
        result = {'success': True, 'answer': answer}
        if truncated:
            result['truncated'] = True
        print(json.dumps(result, separators=(',', ':')))

    except json.JSONDecodeError as e:
        print(json.dumps({'success': False, 'error': f'Invalid JSON: {str(e)}'}, separators=(',', ':')))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({'success': False, 'error': str(e)}, separators=(',', ':')))
        sys.exit(1)


if __name__ == '__main__':
    main()
