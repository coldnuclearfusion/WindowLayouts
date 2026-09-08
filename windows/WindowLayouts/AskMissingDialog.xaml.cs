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
        Message.Text = $"‘{layoutName}’ 배치에 포함된 다음 앱을 실행하거나 새 창을 열어야 합니다.\n\n"
            + string.Join("\n", names.Select(n => "• " + n));
    }

    private void Launch_Click(object sender, RoutedEventArgs e) { Choice = Result.Launch; DialogResult = true; }
    private void Skip_Click(object sender, RoutedEventArgs e) { Choice = Result.Skip; DialogResult = true; }
    private void Cancel_Click(object sender, RoutedEventArgs e) { Choice = Result.Cancel; DialogResult = false; }
}
