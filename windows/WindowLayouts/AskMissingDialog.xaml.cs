using System.Collections.Generic;
using System.Linq;
using System.Windows;

namespace WindowLayouts;

public partial class AskMissingDialog : Window
{
    public enum Result { Launch, Skip, Cancel }

    public Result Choice { get; private set; } = Result.Cancel;
    public bool Remember => RememberBox.IsChecked == true;

    public AskMissingDialog(List<string> names, string layoutName)
    {
        InitializeComponent();
        Title = Loc.T("app.name");
        Heading.Text = Loc.T("ask.title");
        Message.Text = Loc.T("ask.message", ("name", layoutName)) + "\n\n"
            + string.Join("\n", names.Select(n => "• " + n));
        RememberBox.Content = Loc.T("ask.remember");
        CancelButton.Content = Loc.T("common.cancel");
        SkipButton.Content = Loc.T("ask.skip");
        LaunchButton.Content = Loc.T("ask.launch");
    }

    private void Launch_Click(object sender, RoutedEventArgs e) { Choice = Result.Launch; DialogResult = true; }
    private void Skip_Click(object sender, RoutedEventArgs e) { Choice = Result.Skip; DialogResult = true; }
    private void Cancel_Click(object sender, RoutedEventArgs e) { Choice = Result.Cancel; DialogResult = false; }
}
