# פרסום התמונה והפעלה ב־Vast

ה־workflow בקובץ `.github/workflows/publish-vast-image.yml` מבצע שלושה שלבים:

1. בדיקות Bash, Python ויחידה.
2. בניית תמונת `linux/amd64` מתוך `Dockerfile.vast`.
3. פרסום התגים `1.2` ו־`latest` ב־GitHub Container Registry.

כתובת התמונה המתוכננת:

```text
ghcr.io/aryedu110-cmd/arye-vast-mobile-ai-stack:1.2
```

המאגר והתמונה מיועדים להיות ציבוריים. הקוד אינו מכיל סודות. משתני `HF_TOKEN`,
`APP_USER` ו־`APP_PASSWORD` מוזנים רק בממשק משתני הסביבה של Vast בעת יצירת
מופע, ולעולם אינם נשמרים ב־GitHub או בתוך התמונה.

בתבנית Vast יש לבחור `Docker ENTRYPOINT` ולהעביר את הארגומנט:

```text
--jupyter-override
```

אין לשכור מופע עד שה־workflow הסתיים בהצלחה והתמונה הציבורית ניתנת למשיכה.

