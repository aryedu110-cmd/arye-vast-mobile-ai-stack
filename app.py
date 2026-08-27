from __future__ import annotations

import json
import os
from pathlib import Path

import gradio as gr

from backend import (
    generate_ltx,
    generate_tts,
    lip_sync,
    schedule_vast_instance_destroy,
    schedule_vast_instance_stop,
    status,
)


CSS = """
.gradio-container {max-width: 980px !important; margin: auto !important; direction: rtl;}
.primary-card {border: 1px solid #ddd; border-radius: 16px; padding: 8px;}
textarea, input {font-size: 16px !important;}
"""


def status_json():
    return status()


with gr.Blocks(title="Arye AI Studio") as demo:
    gr.Markdown("# אולפן הווידאו של אריה\nממשק נייד ל־LTX‑2.5, ליצירת קול בעברית ולסנכרון שפתיים.", rtl=True)
    with gr.Tab("מצב המערכת"):
        status_box = gr.JSON(value=status_json, label="מצב נוכחי")
        refresh = gr.Button("רענן מצב", variant="secondary")
        refresh.click(status_json, outputs=status_box)
        gr.Markdown("במצב דמה כל הכפתורים נבדקים בלי GPU ובלי הורדת משקולות.", rtl=True)

    with gr.Tab("יצירת וידאו"):
        prompt = gr.Textbox(label="פרומפט", lines=5, rtl=True, placeholder="תאר את השוט...")
        reference = gr.Image(label="תמונת רפרנס — לא חובה", type="filepath", sources=["upload"])
        with gr.Row():
            width = gr.Dropdown([512, 768, 960, 1024], value=768, label="רוחב")
            height = gr.Dropdown([512, 544, 768, 1024], value=512, label="גובה")
        with gr.Row():
            frames = gr.Dropdown([49, 73, 97, 121, 241, 361], value=121, label="מספר פריימים")
            seed = gr.Number(value=42, precision=0, label="Seed")
        video_button = gr.Button("צור סרטון", variant="primary")
        video_output = gr.Video(label="תוצאה")
        video_message = gr.Textbox(label="מצב", interactive=False, rtl=True)
        video_button.click(generate_ltx, [prompt, reference, width, height, frames, seed], [video_output, video_message])

    with gr.Tab("קול בעברית"):
        tts_text = gr.Textbox(label="טקסט להקראה", lines=5, rtl=True)
        ref_audio = gr.Audio(label="דוגמת קול — לא חובה", type="filepath", sources=["upload", "microphone"])
        with gr.Row():
            exaggeration = gr.Slider(0, 1, value=0.5, step=0.05, label="עוצמת הבעה")
            cfg_weight = gr.Slider(0, 1, value=0.5, step=0.05, label="היצמדות לקול")
        tts_button = gr.Button("צור קול", variant="primary")
        tts_output = gr.Audio(label="קול שנוצר", type="filepath")
        tts_message = gr.Textbox(label="מצב", interactive=False, rtl=True)
        tts_button.click(generate_tts, [tts_text, ref_audio, exaggeration, cfg_weight], [tts_output, tts_message])

    with gr.Tab("סנכרון שפתיים"):
        lip_video = gr.Video(label="סרטון מקור", sources=["upload"])
        lip_audio = gr.Audio(label="קול", type="filepath", sources=["upload", "microphone"])
        bbox = gr.Slider(-20, 20, value=0, step=1, label="התאמת אזור הפה")
        lip_button = gr.Button("סנכרן שפתיים", variant="primary")
        lip_output = gr.Video(label="תוצאה")
        lip_message = gr.Textbox(label="מצב", interactive=False, rtl=True)
        lip_button.click(lip_sync, [lip_video, lip_audio, bbox], [lip_output, lip_message])

    with gr.Tab("כיבוי השרת"):
        gr.Markdown(
            "## עצירת מופע Vast\n"
            "הפעולה עוצרת את המופע עצמו ומפסיקה את חיוב ה־GPU. "
            "הקבצים נשמרים, ולכן חיוב האחסון ממשיך עד שמוחקים את המופע דרך Vast. "
            "המחיקה אינה זמינה כאן מפני שהיא בלתי הפיכה.",
            rtl=True,
        )
        stop_confirm = gr.Checkbox(
            label="אני מאשר לעצור עכשיו את מופע Vast ולנתק את הממשק",
            value=False,
        )
        stop_button = gr.Button("עצור את מופע Vast", variant="stop")
        stop_message = gr.Textbox(label="מצב הכיבוי", interactive=False, rtl=True)
        stop_button.click(schedule_vast_instance_stop, [stop_confirm], [stop_message])
        gr.Markdown(
            "---\n## מחיקה מלאה — סיום כל החיובים\n"
            "פעולה זו מוחקת לצמיתות את המופע ואת כל הקבצים שעל האחסון המקומי שלו. "
            "השתמש בה רק לאחר שהורדת את התוצרים הדרושים.",
            rtl=True,
        )
        destroy_id = gr.Textbox(
            label="הקלד את מספר המופע (CONTAINER_ID) לאישור",
            rtl=False,
        )
        destroy_confirm = gr.Checkbox(
            label="אני מבין שהמופע וכל הקבצים המקומיים יימחקו לצמיתות",
            value=False,
        )
        destroy_button = gr.Button("מחק את מופע Vast לצמיתות", variant="stop")
        destroy_message = gr.Textbox(label="מצב המחיקה", interactive=False, rtl=True)
        destroy_button.click(
            schedule_vast_instance_destroy,
            [destroy_confirm, destroy_id],
            [destroy_message],
        )

demo.queue(default_concurrency_limit=1)

if __name__ == "__main__":
    user = os.environ.get("APP_USER")
    password = os.environ.get("APP_PASSWORD")
    auth = (user, password) if user and password else None
    if os.environ.get("GRADIO_SERVER_NAME", "127.0.0.1") == "0.0.0.0" and not auth:
        raise RuntimeError("APP_USER and APP_PASSWORD are required when exposing the dashboard externally")

    demo.launch(
        server_name=os.environ.get("GRADIO_SERVER_NAME", "127.0.0.1"),
        server_port=int(os.environ.get("GRADIO_PORT", "7860")),
        auth=auth,
        show_error=True,
        css=CSS,
    )
