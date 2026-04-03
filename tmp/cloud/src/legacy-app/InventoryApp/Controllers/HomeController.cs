using System.Web.Mvc;

namespace InventoryApp.Controllers
{
    public class HomeController : Controller
    {
        public ActionResult Index()
        {
            ViewBag.Title = "在庫管理システム";
            return View();
        }
    }
}
