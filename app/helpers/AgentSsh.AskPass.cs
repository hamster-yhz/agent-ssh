using System;

internal static class Program
{
    public static int Main()
    {
        string password = Environment.GetEnvironmentVariable("AGENT_SSH_PASSWORD");
        if (String.IsNullOrEmpty(password))
        {
            password = Environment.GetEnvironmentVariable("SSH_SPACE_PASSWORD");
        }
        if (password == null)
        {
            return 1;
        }

        Console.WriteLine(password);
        return 0;
    }
}
