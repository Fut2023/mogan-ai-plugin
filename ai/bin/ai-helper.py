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


def call_claude(question, pdf_path=None, api_key=None, max_tokens=16384):
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
        'max_tokens': max_tokens,
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


def call_openai(question, pdf_path=None, api_key=None, max_tokens=16384):
    """Call OpenAI API (GPT-4o) with optional PDF document."""
    import requests

    if not api_key:
        raise ValueError("OpenAI API key is required")

    url = 'https://api.openai.com/v1/chat/completions'
    headers = {
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json'
    }

    content = []

    # Add PDF as images (OpenAI doesn't support PDF directly, convert pages)
    if pdf_path and os.path.exists(pdf_path):
        # Try to send PDF as base64 file for models that support it
        # GPT-4o supports images, so we convert PDF pages to images
        try:
            import subprocess
            import tempfile
            import glob

            with tempfile.TemporaryDirectory() as tmpdir:
                # Use sips on macOS or convert PDF to PNG pages
                # First try pdftoppm if available
                result = subprocess.run(
                    ['which', 'pdftoppm'], capture_output=True, text=True
                )
                if result.returncode == 0:
                    subprocess.run(
                        ['pdftoppm', '-png', '-r', '150', pdf_path, os.path.join(tmpdir, 'page')],
                        capture_output=True, timeout=60
                    )
                else:
                    # Use sips on macOS - convert PDF to PNG
                    subprocess.run(
                        ['sips', '-s', 'format', 'png', pdf_path, '--out', os.path.join(tmpdir, 'page.png')],
                        capture_output=True, timeout=60
                    )

                # Collect all page images
                pages = sorted(glob.glob(os.path.join(tmpdir, 'page*.png')))
                for page_path in pages:
                    with open(page_path, 'rb') as f:
                        img_b64 = base64.b64encode(f.read()).decode('utf-8')
                    content.append({
                        'type': 'image_url',
                        'image_url': {
                            'url': f'data:image/png;base64,{img_b64}',
                            'detail': 'high'
                        }
                    })
        except Exception:
            # If image conversion fails, send as text extraction
            pass

    # Add the question text
    content.append({'type': 'text', 'text': question})

    system_msg = (
        'Your response will be rendered in a LaTeX document. '
        'Use LaTeX formatting ONLY. NEVER use markdown syntax. '
        'For bold use \\textbf{}, for math use $...$ or \\begin{equation}. '
        'NEVER use asterisks for formatting. '
        'Write plain author names without formatting characters between letters.'
    )

    data = {
        'model': 'gpt-4o',
        'max_tokens': max_tokens,
        'messages': [
            {'role': 'system', 'content': system_msg},
            {'role': 'user', 'content': content}
        ]
    }

    response = requests.post(url, headers=headers, json=data, timeout=600)
    response.raise_for_status()

    result = response.json()
    if 'choices' in result and len(result['choices']) > 0:
        text = result['choices'][0]['message']['content']
        truncated = result['choices'][0].get('finish_reason') == 'length'
        return text, truncated
    else:
        raise ValueError("No content in OpenAI response")


def call_grok(question, pdf_path=None, api_key=None, max_tokens=16384):
    """Call xAI Grok API with optional PDF document via Files API."""
    import requests

    if not api_key:
        raise ValueError("Grok API key is required")

    base_url = 'https://api.x.ai/v1'
    auth_header = {'Authorization': f'Bearer {api_key}'}

    file_ids = []

    # Upload PDF via Files API if provided
    if pdf_path and os.path.exists(pdf_path):
        upload_resp = requests.post(
            f'{base_url}/files',
            headers=auth_header,
            files={'file': (os.path.basename(pdf_path), open(pdf_path, 'rb'), 'application/pdf')},
            data={'purpose': 'assistants'},
            timeout=120
        )
        upload_resp.raise_for_status()
        file_id = upload_resp.json().get('id')
        if file_id:
            file_ids.append(file_id)

    system_msg = (
        'Your response will be rendered in a LaTeX document. '
        'Use LaTeX formatting ONLY. NEVER use markdown syntax. '
        'For bold use \\textbf{}, for math use $...$ or \\begin{equation}. '
        'NEVER use asterisks for formatting. '
        'Write plain author names without formatting characters between letters.'
    )

    # Build input with file attachments
    user_content = []
    for fid in file_ids:
        user_content.append({'type': 'file', 'file_id': fid})
    user_content.append({'type': 'text', 'text': question})

    # Use Responses API for file support
    data = {
        'model': 'grok-3-fast',
        'max_output_tokens': max_tokens,
        'input': [
            {'role': 'system', 'content': system_msg},
            {'role': 'user', 'content': user_content}
        ]
    }

    headers = {**auth_header, 'Content-Type': 'application/json'}
    response = requests.post(f'{base_url}/responses', headers=headers, json=data, timeout=600)
    response.raise_for_status()

    result = response.json()

    # Extract text from Responses API output
    text = ''
    truncated = False
    if 'output' in result:
        for item in result['output']:
            if item.get('type') == 'message':
                for content in item.get('content', []):
                    if content.get('type') == 'output_text':
                        text += content.get('text', '')
        truncated = result.get('status') == 'incomplete'
    
    if not text:
        raise ValueError("No content in Grok response")

    return text, truncated


def call_gemini(question, pdf_path=None, api_key=None, max_tokens=16384):
    """Call Google Gemini API with optional PDF document."""
    import requests

    if not api_key:
        raise ValueError("Gemini API key is required")

    url = f'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent?key={api_key}'

    content_parts = []

    # Add PDF document if provided
    if pdf_path and os.path.exists(pdf_path):
        with open(pdf_path, 'rb') as f:
            pdf_b64 = base64.b64encode(f.read()).decode('utf-8')
        content_parts.append({
            'inline_data': {
                'mime_type': 'application/pdf',
                'data': pdf_b64
            }
        })

    # Add the question text
    content_parts.append({'text': question})

    data = {
        'contents': [{'parts': content_parts}],
        'systemInstruction': {
            'parts': [{'text': (
                'Your response will be rendered in a LaTeX document. '
                'Use LaTeX formatting ONLY. NEVER use markdown syntax. '
                'For bold use \\textbf{}, for math use $...$ or \\begin{equation}. '
                'NEVER use asterisks for formatting.'
            )}]
        },
        'generationConfig': {
            'maxOutputTokens': max_tokens
        }
    }

    response = requests.post(url, headers={'Content-Type': 'application/json'}, json=data, timeout=600)
    response.raise_for_status()

    result = response.json()
    if 'candidates' in result and len(result['candidates']) > 0:
        candidate = result['candidates'][0]
        text = candidate['content']['parts'][0]['text']
        truncated = candidate.get('finishReason') == 'MAX_TOKENS'
        return text, truncated
    else:
        raise ValueError("No content in Gemini response")


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
        max_tokens = config.get('max_tokens', 16384)

        if not question:
            raise ValueError("Question is required")

        # Call appropriate provider
        if provider == 'claude':
            answer, truncated = call_claude(question, pdf_path, api_key, max_tokens)
        elif provider == 'openai':
            answer, truncated = call_openai(question, pdf_path, api_key, max_tokens)
        elif provider == 'grok':
            answer, truncated = call_grok(question, pdf_path, api_key, max_tokens)
        elif provider == 'gemini':
            answer, truncated = call_gemini(question, pdf_path, api_key, max_tokens)
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
