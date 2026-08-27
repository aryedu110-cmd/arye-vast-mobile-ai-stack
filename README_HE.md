# חבילת Vast ניידת: LTX‑2.5, MuseTalk ו־Chatterbox

החבילה מכינה שרת GPU לשימוש מהטלפון ומבודדת כל מודל בסביבת Python נפרדת:

- **LTX‑2.5 Distilled** ליצירת וידאו ואודיו.
- **MuseTalk 1.5** לסנכרון שפתיים.
- **Chatterbox Multilingual V3** ליצירת קול ולשכפול קול ב־23 שפות, כולל עברית.
- **Gradio** כממשק נייד מאובטח.
- **OpenMontage** כשכבת תזמור אופציונלית, מוצמדת ל־commit שנבדק ומבודדת בסביבת Python משלה.

## מה אפשר לבדוק ללא שרת

```bash
chmod +x onstart.sh launch.sh scripts/*.sh
STACK_ROOT=/tmp/arye-ai-test SETUP_MODE=validate ./onstart.sh
python3 -m unittest discover -s tests -v
python3 scripts/build_inline_bootstrap.py
```

מצב `validate` אינו מוריד מודלים ואינו דורש GPU. הוא מאמת את קובצי ההגדרות, תחביר Python, דרישות הדיסק והפקודות הבסיסיות. בדיקות היחידה מפעילות את הזרימה במצב דמה.

להצגת ממשק Gradio ללא GPU:

```bash
python3 -m venv .venv-ui
.venv-ui/bin/pip install -r requirements-ui.txt
STACK_ROOT=/tmp/arye-ai-test MOCK_MODE=1 GRADIO_SERVER_NAME=127.0.0.1 .venv-ui/bin/python app.py
```

## הפעלה מומלצת ב־Vast: תמונת Docker נגזרת

המסלול האמין הוא לבנות פעם אחת את `Dockerfile.vast` ולפרסם את התמונה במאגר
Docker ציבורי או פרטי. התמונה **אינה מחליפה** את ה־entrypoint הרשמי של Vast;
היא מוסיפה hook ל־`/etc/vast_boot.d/80-arye-ai-stack.sh`. כך Jupyter, SSH
ו־Instance Portal עולים בדרך הרשמית, והחבילה מתחילה לאחר מכן.

```bash
docker build -f Dockerfile.vast -t <registry>/arye-vast-mobile-ai-stack:v1.2 .
docker push <registry>/arye-vast-mobile-ai-stack:v1.2
```

לפרסום אוטומטי ב־GitHub Container Registry ראו `REGISTRY_HE.md`. קובץ
ה־workflow בודק את החבילה לפני כל פרסום ובונה רק עבור `linux/amd64`, כפי
שנדרש במארחי Vast הנוכחיים.

בתבנית Vast:

1. יש לבחור `Docker ENTRYPOINT`.
2. בשדה הארגומנטים יש להזין `--jupyter-override`.
3. יש לבחור בתמונה שנבנתה, להגדיר 300GB דיסק ולפתוח את הפורט הרצוי לממשק.
4. יש להעתיק את המשתנים מתוך `docker/template-env.example` לממשק המשתנים של Vast.
5. אין להכניס סיסמאות או טוקנים לתמונה, ל־Dockerfile או לקובץ שנשמר במאגר.

ברירת המחדל של התמונה משמידה את המופע לאחר 240 דקות, מתקינה MuseTalk,
Chatterbox ו־OpenMontage, ומשאירה את LTX ואת Gradio כבויים עד להגדרת הסודות
הנדרשים. `0` מבטל במפורש טיימר, אך אינו מומלץ בניסוי בתשלום.

## הפעלה חלופית ב־On-start

1. יש לבחור שרת On‑Demand עם NVIDIA GPU בעל לפחות 48GB VRAM ו־300GB דיסק.
2. יש להדביק את תוכן `vast-onstart-inline.sh` בשדה On‑Start של התבנית.
3. יש להגדיר משתני סביבה:

```text
SETUP_MODE=install
STACK_ROOT=/workspace/ai-stack
HF_TOKEN=<read-only-token>
APP_USER=arye
APP_PASSWORD=<strong-unique-password>
GRADIO_PORT=7860
AUTO_LAUNCH=1
AUTO_STOP_MINUTES=180
AUTO_DESTROY_MINUTES=0
INSTALL_OPENMONTAGE=0
```

`HF_TOKEN` חייב להיות טוקן קריאה בלבד. לפני ההפעלה הראשונה צריך לאשר פעם אחת בדפדפן את תנאי הגישה למאגר `Lightricks/LTX-2.5`. אין להכניס טוקן או סיסמה לתוך הסקריפט עצמו.

המסלול החלופי תלוי בכך שהתבנית החדשה מוחלת בזמן יצירת המופע. אין להסתמך על
`Recreate` של מופע קיים כדי לבדוק שינויי Launch Mode או On-start.

## מנגנוני בטיחות

- ברירת המחדל היא `SETUP_MODE=validate`; הורדות כבדות מתחילות רק כשהוגדר במפורש `install`.
- ההתקנה אידמפוטנטית: כל רכיב שסיים מסומן ולא מותקן מחדש בהפעלה הבאה.
- בהפעלה חוזרת, אם נמצא הסמן `state/stack.done`, טיימר הבטיחות נדרך מחדש,
  הורדות וחבילות אינן מותקנות שוב, ורק ממשק Gradio מופעל מחדש לפי ההגדרות.
- לכל מודל סביבת Python נפרדת כדי למנוע התנגשויות בין LTX, MuseTalk ו־Chatterbox.
- הממשק מסרב להיחשף ל־`0.0.0.0` ללא שם משתמש וסיסמה.
- `AUTO_STOP_MINUTES` עוצר את ה־GPU ומשאיר את האחסון. `AUTO_DESTROY_MINUTES` מוחק את המופע לצמיתות ומפסיק גם את חיוב האחסון; אם שניהם מוגדרים, המחיקה מקבלת קדימות.
- להגדרה `PERSIST_ROOT=/נתיב/של/volume` יש משמעות רק כאשר מחובר Volume קיים. היא שומרת באותו Volume את משקלי המודלים ואת מטמוני Hugging Face, uv, pip ו‑torch, כך שמופע עתידי לא יוריד אותם מחדש. עצם הגדרת המשתנה אינה יוצרת Volume ואינה מוסיפה חיוב.
- בלשונית "כיבוי השרת" יש כפתור עצירה ידני עם תיבת אישור. הבקשה נשלחת לאחר השהיה של חמש שניות כדי שהממשק יספיק להציג אישור.
- עצירה מפסיקה את חיוב ה־GPU ושומרת את הקבצים. **חיוב האחסון ממשיך** עד למחיקת המופע.
- מחיקה מלאה זמינה בלשונית הכיבוי רק לאחר סימון אזהרה והקלדה מדויקת של `CONTAINER_ID`. היא מוחקת את כל הקבצים המקומיים ואינה הפיכה.
- כל הלוגים נשמרים תחת `/workspace/ai-stack/logs`.

## OpenMontage

המתקין האופציונלי מוריד את OpenMontage מ־GitHub ב־commit
`cd9f3c1f03368be87b140af494914b8ee4e3c7a4`, בודק SHA-256 ומתקין אותו
בסביבה מבודדת. הוא אינו מתקין Torch נוסף ואינו משנה את סביבות המודלים. החיבור
ל־LTX‑2.5, MuseTalk ו־Chatterbox ייעשה בהמשך באמצעות מתאמי HTTP/ComfyUI; אין
להניח תאימות plug-and-play.

## מה עדיין מחייב בדיקת GPU אמיתית

- התאמת CUDA ודרייבר לתמונה שנבחרה ב־Vast.
- טעינת משקולות LTX‑2.5 ל־VRAM ויצירת MP4 אמיתי.
- תאימות MuseTalk 1.5 לחבילת CUDA של השרת. זה הרכיב הוותיק והרגיש ביותר בחבילה.
- איכות ההגייה בעברית של Chatterbox. המודל מצהיר על תמיכה בעברית, אך יש לבדוק בפועל ניקוד, מספרים ושמות פרטיים.

## מקורות רשמיים

- LTX‑2.5: https://github.com/Lightricks/LTX-2
- משקולות LTX‑2.5: https://huggingface.co/Lightricks/LTX-2.5
- MuseTalk: https://github.com/TMElyralab/MuseTalk
- Chatterbox: https://github.com/resemble-ai/chatterbox
