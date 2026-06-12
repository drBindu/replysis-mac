using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Wordprocessing;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace InterviewCopilotMac6
{
    /// <summary>
    /// Extracts plain text from uploaded resume files (PDF, DOCX, TXT) so it can be
    /// dropped straight into the resume box, same as the "upload your resume" flow
    /// on sites like Parakeet/Final Round AI.
    /// </summary>
    public static class ResumeFileReader
    {
        public static readonly string[] SupportedExtensions = { ".pdf", ".docx", ".txt" };

        public readonly record struct Result(bool Success, string Text, string Error);

        public static bool IsSupported(string fileName) =>
            SupportedExtensions.Contains(Path.GetExtension(fileName).ToLowerInvariant());

        public static async Task<Result> ExtractTextAsync(string filePath)
        {
            try
            {
                string ext = Path.GetExtension(filePath).ToLowerInvariant();
                string raw = ext switch
                {
                    ".pdf"  => ExtractPdfText(filePath),
                    ".docx" => ExtractDocxText(filePath),
                    ".txt"  => await File.ReadAllTextAsync(filePath),
                    _       => throw new NotSupportedException(
                        $"Unsupported file type \"{ext}\". Please upload a PDF, DOCX, or TXT resume.")
                };

                string text = CleanText(raw);
                if (string.IsNullOrWhiteSpace(text))
                    return new Result(false, "", "Couldn't find any text in this file — it may be a scanned/image-based PDF. Try pasting your resume text instead.");

                return new Result(true, text, "");
            }
            catch (NotSupportedException ex)
            {
                return new Result(false, "", ex.Message);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[RESUME] ExtractTextAsync failed: {ex}");
                return new Result(false, "", $"Couldn't read this file: {ex.Message}");
            }
        }

        private static string ExtractPdfText(string path)
        {
            using var pdf = PdfDocument.Open(path);
            var sb = new StringBuilder();
            foreach (var page in pdf.GetPages())
            {
                sb.AppendLine(ContentOrderTextExtractor.GetText(page));
                sb.AppendLine();
            }
            return sb.ToString();
        }

        private static string ExtractDocxText(string path)
        {
            using var doc = WordprocessingDocument.Open(path, false);
            var body = doc.MainDocumentPart?.Document?.Body;
            if (body == null) return "";

            var sb = new StringBuilder();
            foreach (var element in body.Descendants())
            {
                switch (element)
                {
                    case Paragraph:
                    case TableRow:
                        sb.Append('\n');
                        break;
                    case Text t:
                        sb.Append(t.Text);
                        break;
                    case TabChar:
                        sb.Append('\t');
                        break;
                    case Break:
                        sb.Append('\n');
                        break;
                }
            }
            return sb.ToString();
        }

        /// <summary>
        /// Normalizes line endings/whitespace so the parser's line-based heuristics
        /// (job headers, date ranges, skill sections) work the same as pasted text.
        /// </summary>
        private static string CleanText(string text)
        {
            text = text.Replace("\r\n", "\n").Replace('\r', '\n');

            var lines = text.Split('\n')
                .Select(l => l.TrimEnd())
                .ToList();

            var sb = new StringBuilder();
            int blankRun = 0;
            foreach (var line in lines)
            {
                if (line.Length == 0)
                {
                    blankRun++;
                    if (blankRun > 1) continue; // collapse 2+ blank lines into one
                }
                else
                {
                    blankRun = 0;
                }
                sb.AppendLine(line);
            }

            return sb.ToString().Trim();
        }
    }
}
